require "webrick"
require "webrick/httpproxy"
require "webrick/https"
require "stringio"
require "zlib"

class StubHTTPServer
  attr_reader :requests, :port

  def initialize(enable_compression: false)
    @enable_compression = enable_compression
    base_opts = {
      BindAddress: '127.0.0.1',
      Port: 0,  # Let OS assign an available port
      AccessLog: [],
      Logger: NullLogger.new,
      RequestCallback: method(:record_request),
    }
    @server = create_server(base_opts)
    @requests = []
    @requests_queue = Queue.new
  end

  def create_server(base_opts)
    server = WEBrick::HTTPServer.new(base_opts)
    # Get the actual port assigned by the OS
    @port = server.config[:Port]
    server
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
    request = r[0]
    body = r[1]

    return [request, body.to_s] unless @enable_compression

    gz = Zlib::GzipReader.new(StringIO.new(body.to_s))

    [request, gz.read]
  end
end

class NullLogger
  def method_missing(*)
    self
  end
end

def with_server(enable_compression: false)
  server = StubHTTPServer.new(enable_compression: enable_compression)
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
