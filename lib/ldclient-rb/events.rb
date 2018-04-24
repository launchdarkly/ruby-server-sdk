require "concurrent"
require "concurrent/atomics"
require "concurrent/executors"
require "thread"
require "time"
require "faraday"

module LaunchDarkly
  MAX_FLUSH_WORKERS = 5

  class NullEventProcessor
    def add_event(event)
    end

    def flush
    end

    def stop
    end
  end

  class EventMessage
    def initialize(event)
      @event = event
    end
    attr_reader :event
  end

  class FlushMessage
  end

  class FlushUsersMessage
  end

  class SynchronousMessage
    def initialize
      @reply = Concurrent::Semaphore.new(0)
    end
    
    def completed
      @reply.release
    end

    def wait_for_completion
      @reply.acquire
    end
  end

  class TestSyncMessage < SynchronousMessage
  end

  class StopMessage < SynchronousMessage
  end

  class EventProcessor
    def initialize(sdk_key, config, client = nil)
      @queue = Queue.new
      @flush_task = Concurrent::TimerTask.new(execution_interval: config.flush_interval) do
        @queue << FlushMessage.new
      end
      @flush_task.execute
      @users_flush_task = Concurrent::TimerTask.new(execution_interval: config.user_keys_flush_interval) do
        @queue << FlushUsersMessage.new
      end
      @users_flush_task.execute
      @stopped = Concurrent::AtomicBoolean.new(false)
      
      EventDispatcher.new(@queue, sdk_key, config, client)
    end

    def add_event(event)
      event[:creationDate] = (Time.now.to_f * 1000).to_i
      @queue << EventMessage.new(event)
    end

    def flush
      # flush is done asynchronously
      @queue << FlushMessage.new
    end

    def stop
      # final shutdown, which includes a final flush, is done synchronously
      if @stopped.make_true
        @flush_task.shutdown
        @users_flush_task.shutdown
        @queue << FlushMessage.new
        stop_msg = StopMessage.new
        @queue << stop_msg
        stop_msg.wait_for_completion
      end
    end

    # exposed only for testing
    def wait_until_inactive
      sync_msg = TestSyncMessage.new
      @queue << sync_msg
      sync_msg.wait_for_completion
    end
  end

  class EventDispatcher
    def initialize(queue, sdk_key, config, client)
      @sdk_key = sdk_key
      @config = config
      @client = client ? client : Faraday.new
      @user_keys = SimpleLRUCacheSet.new(config.user_keys_capacity)
      @formatter = EventOutputFormatter.new(config)
      @disabled = Concurrent::AtomicBoolean.new(false)
      @last_known_past_time = Concurrent::AtomicFixnum.new(0)

      buffer = EventBuffer.new(config.capacity, config.logger)
      flush_workers = NonBlockingThreadPool.new(MAX_FLUSH_WORKERS)

      Thread.new { main_loop(queue, buffer, flush_workers) }
    end

    private

    def now_millis()
      (Time.now.to_f * 1000).to_i
    end

    def main_loop(queue, buffer, flush_workers)
      running = true
      while running do
        begin
          message = queue.pop
          case message
          when EventMessage
            dispatch_event(message.event, buffer)
          when FlushMessage
            trigger_flush(buffer, flush_workers)
          when FlushUsersMessage
            @user_keys.clear
          when TestSyncMessage
            synchronize_for_testing(flush_workers)
            message.completed
          when StopMessage
            do_shutdown(flush_workers)
            running = false
            message.completed
          end
        rescue => e
          @config.logger.warn { "[LDClient] Unexpected error in event processor: #{e.inspect}. \nTrace: #{e.backtrace}" }
        end
      end
    end

    def do_shutdown(flush_workers)
      flush_workers.shutdown
      flush_workers.wait_for_termination
      # There seems to be no such thing as "close" in Faraday: https://github.com/lostisland/faraday/issues/241
    end

    def synchronize_for_testing(flush_workers)
      # Used only by unit tests. Wait until all active flush workers have finished.
      flush_workers.wait_all
    end

    def dispatch_event(event, buffer)
      return if @disabled.value

      # Always record the event in the summary.
      buffer.add_to_summary(event)

      # Decide whether to add the event to the payload. Feature events may be added twice, once for
      # the event (if tracked) and once for debugging.
      will_add_full_event = false
      debug_event = nil
      if event[:kind] == "feature"
        will_add_full_event = event[:trackEvents]
        if should_debug_event(event)
          debug_event = event.clone
          debug_event[:debug] = true
        end
      else
        will_add_full_event = true
      end

      # For each user we haven't seen before, we add an index event - unless this is already
      # an identify event for that user.
      if !(will_add_full_event && @config.inline_users_in_events)
        if event.has_key?(:user) && !notice_user(event[:user]) && event[:kind] != "identify"
          buffer.add_event({
            kind: "index",
            creationDate: event[:creationDate],
            user: event[:user]
          })
        end
      end

      buffer.add_event(event) if will_add_full_event
      buffer.add_event(debug_event) if !debug_event.nil?
    end

    # Add to the set of users we've noticed, and return true if the user was already known to us.
    def notice_user(user)
      if user.nil? || !user.has_key?(:key)
        true
      else
        @user_keys.add(user[:key])
      end
    end

    def should_debug_event(event)
      debug_until = event[:debugEventsUntilDate]
      if !debug_until.nil?
        last_past = @last_known_past_time.value
        debug_until > last_past && debug_until > now_millis
      else
        false
      end
    end

    def trigger_flush(buffer, flush_workers)
      if @disabled.value
        return
      end

      payload = buffer.get_payload  
      if !payload.events.empty? || !payload.summary.counters.empty?
        # If all available worker threads are busy, success will be false and no job will be queued.
        success = flush_workers.post do
          resp = EventPayloadSendTask.new.run(@sdk_key, @config, @client, payload, @formatter)
          handle_response(resp) if !resp.nil?
        end
        buffer.clear if success # Reset our internal state, these events now belong to the flush worker
      end
    end

    def handle_response(res)
      if res.status == 401
        @config.logger.error { "[LDClient] Received 401 error, no further events will be posted since SDK key is invalid" }
        @disabled.value = true
      else
        if !res.headers.nil? && res.headers.has_key?("Date")
          begin
            res_time = (Time.httpdate(res.headers["Date"]).to_f * 1000).to_i
            @last_known_past_time.value = res_time
          rescue ArgumentError
          end
        end
      end
    end
  end

  FlushPayload = Struct.new(:events, :summary)

  class EventBuffer
    def initialize(capacity, logger)
      @capacity = capacity
      @logger = logger
      @capacity_exceeded = false
      @events = []
      @summarizer = EventSummarizer.new
    end

    def add_event(event)
      if @events.length < @capacity
        @logger.debug { "[LDClient] Enqueueing event: #{event.to_json}" }
        @events.push(event)
        @capacity_exceeded = false
      else
        if !@capacity_exceeded
          @capacity_exceeded = true
          @logger.warn { "[LDClient] Exceeded event queue capacity. Increase capacity to avoid dropping events." }
        end
      end
    end

    def add_to_summary(event)
      @summarizer.summarize_event(event)
    end

    def get_payload
      return FlushPayload.new(@events, @summarizer.snapshot)
    end

    def clear
      @events = []
      @summarizer.clear
    end
  end

  class EventPayloadSendTask
    def run(sdk_key, config, client, payload, formatter)
      events_out = formatter.make_output_events(payload.events, payload.summary)
      res = nil
      body = events_out.to_json
      (0..1).each do |attempt|
        if attempt > 0
          config.logger.warn { "[LDClient] Will retry posting events after 1 second" }
          sleep(1)
        end
        begin
          config.logger.debug { "[LDClient] sending #{events_out.length} events: #{body}" }
          res = client.post (config.events_uri + "/bulk") do |req|
            req.headers["Authorization"] = sdk_key
            req.headers["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
            req.headers["Content-Type"] = "application/json"
            req.headers["X-LaunchDarkly-Event-Schema"] = "2"
            req.body = body
            req.options.timeout = config.read_timeout
            req.options.open_timeout = config.connect_timeout
          end
        rescue StandardError => exn
          config.logger.warn { "[LDClient] Error flushing events: #{exn.inspect}." }
          next
        end
        if res.status < 200 || res.status >= 300
          config.logger.error { "[LDClient] Unexpected status code while processing events: #{res.status}" }
          if res.status >= 500
            next
          end
        end
        break
      end
      # used up our retries, return the last response if any
      res
    end
  end

  class EventOutputFormatter
    def initialize(config)
      @inline_users = config.inline_users_in_events
      @user_filter = UserFilter.new(config)
    end

    # Transforms events into the format used for event sending.
    def make_output_events(events, summary)
      events_out = events.map { |e| make_output_event(e) }
      if !summary.counters.empty?
        events_out.push(make_summary_event(summary))
      end
      events_out
    end

    private

    def make_output_event(event)
      case event[:kind]
      when "feature"
        is_debug = event[:debug]
        out = {
          kind: is_debug ? "debug" : "feature",
          creationDate: event[:creationDate],
          key: event[:key],
          value: event[:value]
        }
        out[:default] = event[:default] if event.has_key?(:default)
        out[:version] = event[:version] if event.has_key?(:version)
        out[:prereqOf] = event[:prereqOf] if event.has_key?(:prereqOf)
        if @inline_users || is_debug
          out[:user] = @user_filter.transform_user_props(event[:user])
        else
          out[:userKey] = event[:user].nil? ? nil : event[:user][:key]
        end
        out
      when "identify"
        {
          kind: "identify",
          creationDate: event[:creationDate],
          key: event[:user].nil? ? nil : event[:user][:key],
          user: @user_filter.transform_user_props(event[:user])
        }
      when "custom"
        out = {
          kind: "custom",
          creationDate: event[:creationDate],
          key: event[:key]
        }
        out[:data] = event[:data] if event.has_key?(:data)
        if @inline_users
          out[:user] = @user_filter.transform_user_props(event[:user])
        else
          out[:userKey] = event[:user].nil? ? nil : event[:user][:key]
        end
        out
      when "index"
        {
          kind: "index",
          creationDate: event[:creationDate],
          user: @user_filter.transform_user_props(event[:user])
        }
      else
        event
      end
    end

    # Transforms the summary data into the format used for event sending.
    def make_summary_event(summary)
      flags = {}
      summary[:counters].each { |ckey, cval|
        flag = flags[ckey[:key]]
        if flag.nil?
          flag = {
            default: cval[:default],
            counters: []
          }
          flags[ckey[:key]] = flag
        end
        c = {
          value: cval[:value],
          count: cval[:count]
        }
        if ckey[:version].nil?
          c[:unknown] = true
        else
          c[:version] = ckey[:version]
        end
        flag[:counters].push(c)
      }
      {
        kind: "summary",
        startDate: summary[:start_date],
        endDate: summary[:end_date],
        features: flags
      }
    end
  end
end
