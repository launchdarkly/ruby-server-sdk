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

  class EventProcessor
    def initialize(sdk_key, config, client)
      @queue = Queue.new
      @events = []
      @summarizer = EventSummarizer.new(config)
      @sdk_key = sdk_key
      @config = config
      @user_filter = UserFilter.new(config)
      @client = client ? client : Faraday.new
      @stopped = Concurrent::AtomicBoolean.new(false)
      @capacity_exceeded = false
      @last_known_past_time = Concurrent::AtomicFixnum.new(0)
      @flush_task = Concurrent::TimerTask.new(execution_interval: @config.flush_interval) do
        @queue << [:flush, nil]
      end
      @users_flush_task = Concurrent::TimerTask.new(execution_interval: @config.user_keys_flush_interval) do
        @queue << [:flush_users, nil]
      end
      Thread.new { main_loop }
    end

    def stop
      flush
      if @stopped.make_true
        # There seems to be no such thing as "close" in Faraday: https://github.com/lostisland/faraday/issues/241
        @flush_task.shutdown
        @users_flush_task.shutdown
        # Tell the worker thread to stop
        @queue << [:stop]
      end
    end

    def add_event(event)
      return if @stopped.value
      event[:creationDate] = now_millis
      @queue << [:event, event]
    end

    def flush
      return if @stopped.value
      # An explicit flush should be synchronous, so we use a semaphore to wait for the result
      semaphore = Concurrent::Semaphore.new(0)
      @queue << [:flush, semaphore]
      semaphore.acquire
    end

    private

    def now_millis()
      (Time.now.to_f * 1000).to_i
    end

    def main_loop()
      loop do
        begin
          message = @queue.pop
          case message[0]
          when :event
            dispatch_event(message[1])
          when :flush
            flush_internal(message[1])
          when :flush_users
            @summarizer.reset_users
          when :stop
            break
          end
        rescue => e
          @config.logger.warn { "[LDClient] Unexpected error in event processor: #{e.inspect}. \nTrace: #{e.backtrace}" }
        end
      end
    end

    def dispatch_event(event)
      # For each user we haven't seen before, we add an index event - unless this is already
      # an identify event for that user.
      if !@config.inline_users_in_events && event.has_key?(:user) && !@summarizer.notice_user(event[:user])
        if event[:kind] != "identify"
          queue_event({
            kind: "index",
            creationDate: event[:creationDate],
            user: @user_filter.transform_user_props(event[:user])
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

    def flush_internal(reply_semaphore)
      old_events = @events
      @events = []
      snapshot = @summarizer.snapshot
  
      if !@stopped.value && (!old_events.empty? || !snapshot[:counters].empty?)
        Thread.new do
          begin
            post_flushed_events(old_events, snapshot)
          rescue StandardError => exn
            @config.logger.warn { "[LDClient] Error flushing events: #{exn.inspect}. \nTrace: #{exn.backtrace}" }
          end
          reply_semaphore.release if !reply_semaphore.nil?
        end
      else
        reply_semaphore.release if !reply_semaphore.nil?
      end
    end

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
      else
        event
      end
    end

    def post_flushed_events(events, snapshot)
      events_out = events.map { |e| make_output_event(e) }
      if !snapshot[:counters].empty?
        summary_output = @summarizer.output(snapshot)
        summary_output[:kind] = "summary"
        events_out.push(summary_output)
      end
      res = @client.post (@config.events_uri + "/bulk") do |req|
        req.headers["Authorization"] = @sdk_key
        req.headers["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
        req.headers["Content-Type"] = "application/json"
        req.body = events_out.to_json
        req.options.timeout = @config.read_timeout
        req.options.open_timeout = @config.connect_timeout
      end
      if res.status < 200 || res.status >= 300
        @config.logger.error { "[LDClient] Unexpected status code while processing events: #{res.status}" }
        if res.status == 401
          @config.logger.error { "[LDClient] Received 401 error, no further events will be posted since SDK key is invalid" }
          stop
        end
      else
        if !res.headers.nil? && res.headers.has_key?("Date")
          begin
            res_time = (Time.httpdate(res.headers["Date"]).to_f * 1000).to_i
            @last_known_past_time.value = res_time
          rescue
          end
        end
      end
    end
  end
end
