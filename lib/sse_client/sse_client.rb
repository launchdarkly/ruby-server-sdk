require "concurrent/atomics"
require "logger"
require "thread"
require "uri"

module SSE
  #
  # A lightweight Server-Sent Events implementation, relying on two gems: socketry for sockets with
  # read timeouts, and http_tools for HTTP response parsing. The overall logic is based on
  # [https://github.com/Tonkpils/celluloid-eventsource].
  #
  class SSEClient
    DEFAULT_CONNECT_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 300
    DEFAULT_RECONNECT_TIME = 1
    MAX_RECONNECT_TIME = 30

    def initialize(uri, options = {})
      @uri = URI(uri)
      @stopped = Concurrent::AtomicBoolean.new(false)

      @headers = options[:headers] ? options[:headers].clone : {}
      @connect_timeout = options[:connect_timeout] || DEFAULT_CONNECT_TIMEOUT
      @read_timeout = options[:read_timeout] || DEFAULT_READ_TIMEOUT
      @logger = options[:logger] || default_logger

      if options[:proxy]
        @proxy = options[:proxy]
      else
        proxyUri = @uri.find_proxy
        if !proxyUri.nil? && (proxyUri.scheme == 'http' || proxyUri.scheme == 'https')
          @proxy = proxyUri
        end
      end

      reconnect_time = options[:reconnect_time] || DEFAULT_RECONNECT_TIME
      @backoff = Backoff.new(reconnect_time, MAX_RECONNECT_TIME)

      @on = { event: ->(_) {}, error: ->(_) {} }
      @last_id = nil

      yield self if block_given?

      Thread.new do
        run_stream
      end
    end

    def on(event_name, &action)
      @on[event_name.to_sym] = action
    end

    def on_event(&action)
      @on[:event] = action
    end

    def on_error(&action)
      @on[:error] = action
    end

    def close
      if @stopped.make_true
        @cxn.close if !@cxn.nil?
      end
    end

    private

    def default_logger
      log = ::Logger.new($stdout)
      log.level = ::Logger::WARN
      log
    end

    def run_stream
      while !@stopped.value
        @cxn = nil
        begin
          @cxn = connect
          read_stream(@cxn) if !@cxn.nil?
        rescue Errno::EBADF
          # don't log this - it probably means we closed our own connection deliberately
        rescue StandardError => e
          @logger.error { "Unexpected error from event source: #{e.inspect}" }
          @logger.debug { "Exception trace: #{e.backtrace}" }
        end
        @cxn.close if !@cxn.nil?
      end
    end

    # Try to establish a streaming connection. Returns the StreamingHTTPConnection object if successful.
    def connect
      loop do
        return if @stopped.value
        interval = @backoff.next_interval
        if interval > 0
          @logger.warn { "Will retry connection after #{'%.3f' % interval} seconds" } 
          sleep(interval)
        end
        begin
          cxn = open_connection(build_headers)
          if cxn.status != 200
            body = cxn.read_all  # grab the whole response body in case it has error details
            cxn.close
            @on[:error].call({status_code: cxn.status, body: body})
            next
          elsif cxn.headers["content-type"] && cxn.headers["content-type"].start_with?("text/event-stream")
            return cxn  # we're good to proceed
          end
          @logger.error { "Event source returned unexpected content type '#{cxn.headers["content-type"]}'" }
        rescue Errno::EBADF
          raise
        rescue StandardError => e
          @logger.error { "Unexpected error from event source: #{e.inspect}" }
          @logger.debug { "Exception trace: #{e.backtrace}" }
          cxn.close if !cxn.nil?
        end
        # if unsuccessful, continue the loop to connect again
      end
    end

    # Just calls the StreamingHTTPConnection constructor - factored out for test purposes
    def open_connection(headers)
      StreamingHTTPConnection.new(@uri, @proxy, headers, @connect_timeout, @read_timeout)
    end

    # Pipe the output of the StreamingHTTPConnection into the EventParser, and dispatch events as
    # they arrive.
    def read_stream(cxn)
      event_parser = EventParser.new(cxn.read_lines)
      event_parser.items.each do |item|
        return if @stopped.value
        case item
          when SSEEvent
            dispatch_event(item)
          when SSESetRetryInterval
            @backoff.base_interval = event.milliseconds.t-Of / 1000
        end
      end
    end

    def dispatch_event(event)
      @last_id = event.id

      # Tell the Backoff object that as of the current time, we have succeeded in getting some data. It
      # uses that information so it can automatically reset itself if enough time passes between failures.
      @backoff.mark_success

      # Pass the event to the caller
      @on[:event].call(event)
    end

    def build_headers
      h = {
        'Accept' => 'text/event-stream',
        'Cache-Control' => 'no-cache'
      }
      h['Last-Event-Id'] = @last_id if !@last_id.nil?
      h.merge(@headers)
    end
  end
end
