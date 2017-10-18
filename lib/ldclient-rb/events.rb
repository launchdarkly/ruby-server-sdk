require "thread"
require "faraday"

module LaunchDarkly
  class EventProcessor
    def initialize(sdk_key, config)
      @queue = Queue.new
      @sdk_key = sdk_key
      @config = config
      @serializer = EventSerializer.new(config)
      @client = Faraday.new
      @worker = create_worker if @config.send_events
    end

    def create_worker
      Thread.new do
        loop do
          begin
            flush
            sleep(@config.flush_interval)
          rescue StandardError => exn
            log_exception(__method__.to_s, exn)
          end
        end
      end
    end

    def post_flushed_events(events)
      res = @client.post (@config.events_uri + "/bulk") do |req|
        req.headers["Authorization"] = @sdk_key
        req.headers["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
        req.headers["Content-Type"] = "application/json"
        req.body = @serializer.serialize_events(events)
        req.options.timeout = @config.read_timeout
        req.options.open_timeout = @config.connect_timeout
      end
      if res.status < 200 || res.status >= 300
        @config.logger.error("[LDClient] Unexpected status code while processing events: #{res.status}")
      end
    end

    def flush
      return if @offline || !@config.send_events
      events = []
      begin
        loop do
          events << @queue.pop(true)
        end
      rescue ThreadError
      end

      if !events.empty?
        post_flushed_events(events)
      end
    end

    def add_event(event)
      return if @offline || !@config.send_events

      if @queue.length < @config.capacity
        event[:creationDate] = (Time.now.to_f * 1000).to_i
        @config.logger.debug("[LDClient] Enqueueing event: #{event.to_json}")
        @queue.push(event)

        if !@worker.alive?
          @worker = create_worker
        end
      else
        @config.logger.warn("[LDClient] Exceeded event queue capacity. Increase capacity to avoid dropping events.")
      end
    end

    private :create_worker, :post_flushed_events
  end
end
