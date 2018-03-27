require "concurrent"
require "concurrent/atomics"
require "thread"
require "time"
require "faraday"

module LaunchDarkly
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
    def initialize(synchronous)
      @reply = synchronous ? Concurrent::Semaphore.new(0) : nil
    end
    
    attr_reader :reply

    def completed
      @reply.release if !@reply.nil?
    end

    def wait_for_completion
      @reply.acquire if !@reply.nil?
    end
  end

  class FlushUsersMessage
  end

  class StopMessage
  end

  class EventProcessor
    def initialize(sdk_key, config, client)
      @queue = Queue.new
      @flush_task = Concurrent::TimerTask.new(execution_interval: config.flush_interval) do
        @queue << FlushMessage.new(false)
      end
      @users_flush_task = Concurrent::TimerTask.new(execution_interval: config.user_keys_flush_interval) do
        @queue << FlushUsersMessage.new
      end
      @consumer = EventConsumer.new(@queue, sdk_key, config, client)
      @consumer.start
    end

    def stop
      @flush_task.shutdown
      @users_flush_task.shutdown
      flush
      @consumer.stop
    end

    def add_event(event)
      event[:creationDate] = (Time.now.to_f * 1000).to_i
      @queue << EventMessage.new(event)
    end

    def flush
      # An explicit flush should be synchronous, so we use a semaphore to wait for the result
      message = FlushMessage.new(true)
      @queue << message
      message.wait_for_completion
    end
  end

  class EventConsumer
    def initialize(queue, sdk_key, config, client)
      @queue = queue
      @sdk_key = sdk_key
      @config = config
      @client = client ? client : Faraday.new
      @events = []
      @summarizer = EventSummarizer.new
      @user_keys = SimpleLRUCacheSet.new(config.user_keys_capacity)
      @stopped = Concurrent::AtomicBoolean.new(false)
      @disabled = Concurrent::AtomicBoolean.new(false)
      @capacity_exceeded = false
      @last_known_past_time = Concurrent::AtomicFixnum.new(0)
    end

    def start
      Thread.new { main_loop }
    end

    def stop
      if @stopped.make_true
        # There seems to be no such thing as "close" in Faraday: https://github.com/lostisland/faraday/issues/241
        # Tell the worker thread to stop
        @queue << StopMessage.new
      end
    end

    private

    def now_millis()
      (Time.now.to_f * 1000).to_i
    end

    def main_loop()
      loop do
        begin
          message = @queue.pop
          case message
          when EventMessage
            dispatch_event(message.event)
          when FlushMessage
            flush_internal(message)
          when FlushUsersMessage
            @user_keys.reset
          when StopMessage
            break
          end
        rescue => e
          @config.logger.warn { "[LDClient] Unexpected error in event processor: #{e.inspect}. \nTrace: #{e.backtrace}" }
        end
      end
    end

    def dispatch_event(event)
      return if @disabled.value

      # For each user we haven't seen before, we add an index event - unless this is already
      # an identify event for that user.
      if !@config.inline_users_in_events && event.has_key?(:user) && !notice_user(event[:user])
        if event[:kind] != "identify"
          queue_event({
            kind: "index",
            creationDate: event[:creationDate],
            user: event[:user]
          })
        end
      end

      # Always record the event in the summary.
      @summarizer.summarize_event(event)

      if should_track_full_event(event)
        # Queue the event as-is; we'll transform it into an output event when we're flushing.
        queue_event(event)
      end
    end

    # Add to the set of users we've noticed, and return true if the user was already known to us.
    def notice_user(user)
      if user.nil? || !user.has_key?(:key)
        true
      else
        @user_keys.add(user[:key])
      end
    end

    def should_track_full_event(event)
      if event[:kind] == "feature"
        if event[:trackEvents]
          true
        else
          if event.has_key?(:debugEventsUntilDate)
            debugUntil = event[:debugEventsUntilDate]
            last_past = @last_known_past_time.value
            debugUntil > last_past && debugUntil > now_millis
          else
            false
          end
        end
      else
        true
      end
    end

    def queue_event(event)
      if @events.length < @config.capacity
        @config.logger.debug { "[LDClient] Enqueueing event: #{event.to_json}" }
        @events.push(event)
        @capacity_exceeded = false
      else
        if !@capacity_exceeded
          @capacity_exceeded = true
          @config.logger.warn { "[LDClient] Exceeded event queue capacity. Increase capacity to avoid dropping events." }
        end
      end
    end

    def flush_internal(message)
      if @disabled.value
        message.completed
        return
      end

      old_events = @events
      @events = []
      snapshot = @summarizer.snapshot
  
      if !old_events.empty? || !snapshot[:counters].empty?
        task = EventPayloadSendTask.new(@sdk_key, @config, @client, old_events, snapshot,
          message, method(:on_event_response))
        task.start
      else
        message.completed
      end
    end

    def on_event_response(res)
      if res.status < 200 || res.status >= 300
        @config.logger.error { "[LDClient] Unexpected status code while processing events: #{res.status}" }
        if res.status == 401
          @config.logger.error { "[LDClient] Received 401 error, no further events will be posted since SDK key is invalid" }
          @disabled.value = true
        end
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

  class EventPayloadSendTask
    def initialize(sdk_key, config, client, events, summary, message, response_callback)
      @sdk_key = sdk_key
      @config = config
      @client = client
      @events = events
      @summary = summary
      @message = message
      @response_callback = response_callback
      @user_filter = UserFilter.new(config)
    end

    def start
      Thread.new do
        begin
          post_flushed_events
        rescue StandardError => exn
          @config.logger.warn { "[LDClient] Error flushing events: #{exn.inspect}. \nTrace: #{exn.backtrace}" }
        end
        @message.completed
      end
    end

    private

    def post_flushed_events
      events_out = @events.map { |e| make_output_event(e) }
      if !@summary[:counters].empty?
        events_out.push(make_summary_event(@summary))
      end
      res = @client.post (@config.events_uri + "/bulk") do |req|
        req.headers["Authorization"] = @sdk_key
        req.headers["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
        req.headers["Content-Type"] = "application/json"
        req.body = events_out.to_json
        req.options.timeout = @config.read_timeout
        req.options.open_timeout = @config.connect_timeout
      end
      @response_callback.call(res)
    end

    # Transforms events into the format used for event sending.
    def make_output_event(event)
      case event[:kind]
      when "feature"
        is_debug = !event[:trackEvents] && event.has_key?(:debugEventsUntilDate)
        out = {
          kind: is_debug ? "debug" : "feature",
          creationDate: event[:creationDate],
          key: event[:key],
          value: event[:value]
        }
        out[:default] = event[:default] if event.has_key?(:default)
        out[:version] = event[:version] if event.has_key?(:version)
        out[:prereqOf] = event[:prereqOf] if event.has_key?(:prereqOf)
        if @config.inline_users_in_events
          out[:user] = @user_filter.transform_user_props(event[:user])
        else
          out[:userKey] = event[:user][:key]
        end
        out
      when "identify"
        {
          kind: "identify",
          creationDate: event[:creationDate],
          user: @user_filter.transform_user_props(event[:user])
        }
      when "custom"
        out = {
          kind: "custom",
          creationDate: event[:creationDate],
          key: event[:key]
        }
        out[:data] = event[:data] if event.has_key?(:data)
        if @config.inline_users_in_events
          out[:user] = @user_filter.transform_user_props(event[:user])
        else
          out[:userKey] = event[:user][:key]
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
