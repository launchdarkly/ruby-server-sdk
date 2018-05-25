require "http"

module LaunchDarkly
  class EventSourceListener
    class Reconnect < RuntimeError
    end

    def initialize(uri, options = {})
      @uri = uri
      @via = options[:via]
      @headers = options[:headers] || {}
      @read_timeout = options[:read_timeout]
      @event_handlers = {}
      @error_handler = nil
    end

    def on(event_type, &data_handling_blk)
      @event_handlers[event_type.to_s] = data_handling_blk
    end

    def on_error(&blk)
      @error_handler = blk
    end

    def start
      client = HTTP.timeout(:read => @read_timeout.to_i)
      if @via
        proxy_options = Faraday::ProxyOptions.from(@via)
        client = client.via(proxy_options.host, proxy_options.port, proxy_options.user, proxy_options.password)
      end

      response = client.get(@uri, :headers => @headers)

      # Only accept 200 as a legal status
      if response.status.to_i != 200
        if @error_handler
          @error_handler.call({:status_code => response.status.to_i})
        end
        return
      end

      # Stream the body and pass it through the parser
      body = response.body
      event_parser = LaunchDarkly::EventStreamParser.new
      while body_chunk = response.body.readpartial
        event_parser << body_chunk
        events = event_parser.take_events
        # Call event handlers
        events.each do |evt|
          @event_handlers[evt.type].call(evt) if @event_handlers[evt.type]
        end
        # See if we were asked to reconnect
        maybe_last_retry_millis = events.map {|e| e.retry }.compact.last
        if maybe_last_retry_millis
          # and if we were - close the client, sleep and then reconnect.
          client.close
          sleep(maybe_last_retry_millis / 1000.0)
          raise Reconnect
        end
      end
    rescue Reconnect
      # Restart the method from the top
      retry
    ensure
      client.close if client
    end

    private
  end
end
