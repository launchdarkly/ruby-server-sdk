require "webrick"
require "webrick/httpproxy"
require "webrick/https"
require "stringio"
require "zlib"

class StubHTTPServer
  attr_reader :requests, :port

  @@next_port = 50000

  def initialize(enable_compression = false)
    @port = StubHTTPServer.next_port
    @enable_compression = enable_compression
    begin
      base_opts = {
        BindAddress: '127.0.0.1',
        Port: @port,
        AccessLog: [],
        Logger: NullLogger.new,
        RequestCallback: method(:record_request),
      }
      @server = create_server(@port, base_opts)
    rescue Errno::EADDRINUSE
      @port = StubHTTPServer.next_port
      retry
    end
    @requests = []
    @requests_queue = Queue.new
  end

  def self.next_port
    p = @@next_port
    @@next_port = (p + 1 < 60000) ? p + 1 : 50000
    p
  end

  def create_server(port, base_opts)
    WEBrick::HTTPServer.new(base_opts)
  end

  def start
    Thread.new { @server.start }
  end

  def stop
    @server.shutdown
  end

  def base_uri
    URI("http://127.0.0.1:#{@port}")
  end

  def setup_response(uri_path, &action)
    @server.mount_proc(uri_path, action)
  end

  def setup_status_response(uri_path, status, headers={})
    setup_response(uri_path) do |req, res|
      res.status = status
      headers.each { |n, v| res[n] = v }
    end
  end

  def setup_ok_response(uri_path, body, content_type=nil, headers={})
    setup_response(uri_path) do |req, res|
      res.status = 200
      res.content_type = content_type unless content_type.nil?
      res.body = body
      headers.each { |n, v| res[n] = v }
    end
  end

  def record_request(req, res)
    @requests.push(req)
    @requests_queue << [req, req.body]
  end

  def await_request_with_body
    r = @requests_queue.pop
    request, body = r[0], r[1]

    return [request, body] unless @enable_compression

    gz = Zlib::GzipReader.new(StringIO.new(body.to_s))

    [request, gz.read]
  end
end

class NullLogger
  def method_missing(*)
    self
  end
end

def with_server(enable_compression = false)
  server = StubHTTPServer.new(enable_compression)
  begin
    server.start
    yield server
  ensure
    server.stop
  end
end

class SocketFactoryFromHash
  def initialize(ports = {})
    @ports = ports
  end

  def open(uri, timeout)
    TCPSocket.new '127.0.0.1', @ports[uri]
  end
end
