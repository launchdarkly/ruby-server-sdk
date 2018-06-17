require "rack"
require "puma"
require "rack/handler/puma"

class DummyServer
  def initialize
    @app = Rack::Builder.new { eval(File.read(File.dirname(__FILE__) + "/config.ru")) }
  end

  def start(host: "0.0.0.0", port: 9123, verbose: false)
    @thread = Thread.new { Rack::Handler::Puma.run(@app, {:Port => port, :Verbose => verbose, :Host => host}) }
  end

  def shutdown
    @thread.exit
  end
end
