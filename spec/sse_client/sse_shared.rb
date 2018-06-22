require "spec_helper"
require "webrick"

class StubHTTPServer
  def initialize
    @port = 50000
    begin
      @server = WEBrick::HTTPServer.new(
        BindAddress: '127.0.0.1',
        Port: @port,
        AccessLog: [],
        Logger: NullLogger.new
      )
    rescue Errno::EADDRINUSE
      @port += 1
      retry
    end
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
end

class NullLogger
  def method_missing(*)
    self
  end
end

def with_server
  server = StubHTTPServer.new
  begin
    server.start
    yield server
  ensure
    server.stop
  end
end
