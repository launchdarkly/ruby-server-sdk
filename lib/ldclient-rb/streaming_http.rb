require "http_tools"
require "socketry"

module LaunchDarkly
  #
  # Wrapper around a socket allowing us to read an HTTP response incrementally, line by line,
  # or to consume the entire response body.
  #
  # The socket is managed by Socketry, which implements the read timeout.
  #
  # Incoming data is fed into an instance of HTTPTools::Parser, which gives us the header and
  # chunks of the body via callbacks.
  #
  class StreamingHTTPConnection
    DEFAULT_CHUNK_SIZE = 10000

    attr_reader :status
    attr_reader :headers

    def initialize(uri, proxy, headers, connect_timeout, read_timeout)
      @parser = HTTPTools::Parser.new
      @buffer = ""
      @read_timeout = read_timeout
      @done = false
      @lock = Mutex.new

      # Provide callbacks for the Parser to give us the headers and body
      have_headers = false
      @parser.on(:header) do
        have_headers = true
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

      # Block until the status code and headers have been successfully read.
      while !have_headers
        raise EOFError if !read_chunk_into_buffer
      end
      @headers = Hash[@parser.header.map { |k,v| [k.downcase, v] }]
      @status = @parser.status_code
    end

    def close
      @socket.close if @socket
      @socket = nil
    end

    # Generator that returns one line of the response body at a time (delimited by \r, \n,
    # or \r\n) until the response is fully consumed or the socket is closed.
    def read_lines
      Enumerator.new do |gen|
        loop do
          line = read_line
          break if line.nil?
          gen.yield line
        end
      end
    end

    # Consumes the entire response body and returns it.
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

    # Build an HTTP request line and headers.
    def build_request(uri, headers)
      ret = "GET #{uri.request_uri} HTTP/1.1\r\n"
      headers.each { |k, v|
        ret << "#{k}: #{v}\r\n"
      }
      ret + "\r\n"
    end

    # Build a proxy connection header.
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

    # Attempt to read some more data from the socket. Return true if successful, false if EOF.
    def read_chunk
      data = @socket.readpartial(DEFAULT_CHUNK_SIZE, timeout: @read_timeout)
      return false if data == :eof
      @parser << data
      true
    end

    # Extract the next line of text from the read buffer, refilling the buffer as needed.
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
end
