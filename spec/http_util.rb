require "webrick"
require "webrick/httpproxy"
require "webrick/https"

class StubHTTPServer
  attr_reader :requests, :port

  @@next_port = 50000

  def initialize
    @port = StubHTTPServer.next_port
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

  def await_request
    r = @requests_queue.pop
    r[0]
  end

  def await_request_with_body
    r = @requests_queue.pop
    [r[0], r[1]]
  end
end

class StubProxyServer < StubHTTPServer
  attr_reader :request_count
  attr_accessor :connect_status

  def initialize
    super
    @request_count = 0
  end

  def create_server(port, base_opts)
    WEBrick::HTTPProxyServer.new(base_opts.merge({
      ProxyContentHandler: proc do |req,res|
        unless @connect_status.nil?
          res.status = @connect_status
        end
        @request_count += 1
      end,
    }))
  end
end

class NullLogger
  def method_missing(*)
    self
  end
end

def with_server(server = nil)
  server = StubHTTPServer.new if server.nil?
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
