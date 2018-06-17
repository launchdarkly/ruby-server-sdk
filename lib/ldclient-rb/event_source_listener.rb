require "http"

module LaunchDarkly
  class EventSourceListener
    class Reconnect < RuntimeError
    end

    def initialize(uri, headers:, via:, on_retry:, read_timeout:, logger:)
      @uri = uri
      @headers = headers
      @via = via
      @on_retry = on_retry
      @read_timeout = read_timeout
      @logger = logger
      @event_handlers = {}
      @error_handler = nil
      @retry_timeout = 0
    end

    def on(event_type, &data_handling_blk)
      @event_handlers[event_type.to_sym] = data_handling_blk
    end

    def on_error(&blk)
      @error_handler = blk
    end

    def start
      @logger.info { "[LDClient] Opening a streaming connection" }
      client = HTTP.timeout(read: @read_timeout.to_i)
      if @via
        proxy_options = Faraday::ProxyOptions.from(@via)
        client = client.via(proxy_options.host, proxy_options.port, proxy_options.user, proxy_options.password)
      end

      response = client.get(@uri, headers: @headers)

      # Only accept 200 as a legal status
      if response.status.to_i != 200
        if response.status.to_i != 401
          @logger.error { "[LDClient] Unexpected status code #{response.status.to_i} from streaming connection" }
        else
          @logger.error { "[LDClient] Received 401 error, SDK key is invalid" }
          @error_handler.call if @error_handler
        end
        return
      end

      # Only accept the response if the "Content-Type" header has the "text/event-stream".
      if response.headers["Content-Type"].nil?
        @logger.error { "[LDClient] Missing Content-Type. Expected text/event-stream" }
        @error_handler.call if @error_handler
        return
      end

      unless response.headers["Content-Type"].include?("text/event-stream")
        @logger.error { "[LDClient] Received #{response.headers["Content-Type"]} Content-Type. Expected text/event-stream" }
        @error_handler.call if @error_handler
        return
      end

      # Stream the body and pass it through the parser.
      event_parser = LaunchDarkly::EventStreamParser.new(->(timeout) { @retry_timeout = timeout })
      while body_chunk = response.body.readpartial
        event_parser.parse_chunk(body_chunk) do |evt|
          @event_handlers[evt.type].call(evt) if @event_handlers[evt.type]
        end

        @logger.info { "[LDClient] Events have been processed" }

        # If the @retry_timeout was set convert it from milliseconds to seconds.
        if @retry_timeout > 0
          on_retry.call([(@retry_timeout / 1000.0).ceil, 1].max)
        end
      end
    rescue => e
      @logger.info { "[LDClient] Reconnecting after exception: #{e}" }
    ensure
      @logger.info { "[LDClient] Closing a streaming connection" }
      client.close if client
    end

    private
  end
end
