require "concurrent/atomics"
require "http_tools"
require "logger"
require "socketry"
require "thread"
require "uri"

module LaunchDarkly
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

      @headers = options[:headers].clone || {}
      @connect_timeout = options[:connect_timeout] || DEFAULT_CONNECT_TIMEOUT
      @read_timeout = options[:read_timeout] || DEFAULT_READ_TIMEOUT
      @logger = options[:logger] || default_logger

      proxy = ENV['HTTP_PROXY'] || ENV['http_proxy'] || options[:proxy]
      if proxy
        proxyUri = URI(proxy)
        if proxyUri.scheme == 'http' || proxyUri.scheme == 'https'
          @proxy = proxyUri
        end
      end

      reconnect_time = options[:reconnect_time] || DEFAULT_RECONNECT_TIME
      @backoff = Backoff.new(reconnect_time, MAX_RECONNECT_TIME)

      @on = { event: ->(_) {}, error: ->(_) {} }
      @last_id = nil

      yield self if block_given?

      @worker = Thread.new do
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
        @worker.raise ShutdownSignal.new
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
        cxn = nil
        begin
          cxn = connect
          read_stream(cxn)
        rescue ShutdownSignal
          return
        rescue StandardError => e
          @logger.error("Unexpected error from event source: #{e.inspect} #{e.backtrace}")
          cxn.close if !cxn.nil?
        end
      end
    end

    def connect
      loop do
        interval = @backoff.next_interval
        if interval > 0
          @logger.warn("Will retry connection after #{'%.3f' % interval} seconds")
          sleep(interval)
        end
        begin
          cxn = StreamingHTTPConnection.new(@uri, @proxy, build_headers, @connect_timeout, @read_timeout)
          resp_status, resp_headers = cxn.read_headers
          if resp_status != 200
            body = cxn.consume_body
            cxn.close
            @on[:error].call({status_code: resp_status, body: body})
          elsif resp_headers["content-type"] && resp_headers["content-type"].start_with?("text/event-stream")
            return cxn
          end
          @logger.error("Event source returned unexpected content type '#{resp_headers["content-type"]}'")
        rescue StandardError => e
          @logger.error("Unexpected error from event source: #{e.inspect} #{e.backtrace}")
          cxn.close if !cxn.nil?
        end
      end
    end

    def read_stream(cxn)
      event_parser = EventParser.new
      event_parser.on(:event) do |event|
        dispatch_event(event)
      end
      event_parser.on(:retry) do |interval|
        @backoff.base_interval = interval / 1000
      end
      cxn.read_lines.each do |line|
        event_parser << line
      end
    end

    def dispatch_event(event)
      @last_id = event.id
      @backoff.mark_success
      @on[:event].call(event)
    end

    def build_headers
      h = {
        'Accept' => 'text/event-stream',
        'Cache-Control' => 'no-cache',
        'Host' => @uri.host
      }
      h['Last-Event-Id'] = @last_id if !@last_id.nil?
      h.merge(@headers)
    end
  end

  class ShutdownSignal < StandardError
  end

  class StreamingHTTPConnection
    DEFAULT_CHUNK_SIZE = 10000

    def initialize(uri, proxy, headers, connect_timeout, read_timeout)
      @parser = HTTPTools::Parser.new
      @headers = nil
      @buffer = ""
      @read_timeout = read_timeout
      @done = false
      @lock = Mutex.new

      @parser.on(:header) do
        @headers = Hash[@parser.header.map { |k,v| [k.downcase, v] }]
      end
      @parser.on(:stream) do |data|
        @lock.synchronize { @buffer << data }
      end
      @parser.on(:finish) do
        @lock.synchronize { @done = true }
      end

      if proxy
        @socket = open_socket(proxy, connect_timeout)
        @socket.write(build_proxy_request(uri, proxy))
      else
        @socket = open_socket(uri, connect_timeout)
      end

      @socket.write(build_request(uri, headers))
    end

    def close
      @socket.close if @socket
      @socket = nil
    end

    def read_headers
      while @headers.nil? && read_chunk
      end
      [@parser.status_code, @headers]
    end

    def read_lines
      Enumerator.new do |gen|
        loop do
          line = read_line
          break if line.nil?
          gen.yield line
        end
      end
    end

    def consume_body
      loop do
        @lock.synchronize { break if @done }
        break if !read_chunk
      end
      @buffer
    end

    private

    def open_socket(uri, connect_timeout)
      if uri.scheme == 'https'
        Socketry::SSL::Socket.connect(uri.host, uri.port, timeout: connect_timeout)
      else
        Socketry::TCP::Socket.connect(uri.host, uri.port, timeout: connect_timeout)
      end
    end

    def build_request(uri, headers)
      ret = "GET #{uri.request_uri} HTTP/1.1\r\n"
      headers.each { |k, v|
        ret << "#{k}: #{v}\r\n"
      }
      ret + "\r\n"
    end

    def build_proxy_request(uri, proxy)
      ret = "CONNECT #{uri.host}:#{uri.port} HTTP/1.1\r\n"
      ret << "Host: #{uri.host}:#{uri.port}\r\n"
      if proxy.user || proxy.password
        encoded_credentials = Base64.strict_encode64([proxy.user || '', proxy.password || ''].join(":"))
        ret << "Proxy-Authorization: Basic #{encoded_credentials}\r\n"
      end
      ret << "\r\n"
      ret
    end

    def read_chunk
      data = @socket.readpartial(DEFAULT_CHUNK_SIZE, timeout: @read_timeout)
      return false if data == :eof
      @parser << data
      true
    end

    def read_line
      loop do
        @lock.synchronize do
          return nil if @done
          i = @buffer.index(/[\r\n]/)
          if !i.nil?
            i += 1 if (@buffer[i] == "\r" && i < @buffer.length - 1 && @buffer[i + 1] == "\n")
            return @buffer.slice!(0, i + 1).force_encoding(Encoding::UTF_8)
          end
        end
        return nil if !read_chunk
      end
    end
  end

  SSEEvent = Struct.new(:type, :data, :id)
  
  class EventParser
    def initialize
      @on = { event: ->(_) {}, retry: ->(_) {} }
      reset
    end

    def on(event_name, &action)
      @on[event_name] = action
    end

    def <<(line)
      line.chomp!
      if line.empty?
        return if @data.empty?
        event = SSEEvent.new(@type || :message, @data, @id)
        reset
        @on[:event].call(event)
      else
        case line
          when /^:.*$/
          when /^(\w+): ?(.*)$/
            process_field($1, $2)
        end
      end
    end

    private

    def reset
      @id = nil
      @type = nil
      @data = ""
    end

    def process_field(name, value)
      case name
        when "event"
          @type = value.to_sym
        when "data"
          @data << "\n" if !@data.empty?
          @data << value
        when "id"
          @id = field_value
        when "retry"
          if /^(?<num>\d+)$/ =~ value
            @on_retry.call(num.to_i)
          end
      end
    end
  end
end
