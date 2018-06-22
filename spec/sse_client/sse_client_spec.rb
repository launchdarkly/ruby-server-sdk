require "spec_helper"
require "concurrent/atomics"
require "socketry"
require "sse_client/sse_shared"

#
# End-to-end tests of SSEClient against a real server
#
describe SSE::SSEClient do
  subject { SSE::SSEClient }

  def with_client(client)
    begin
      yield client
    ensure
      client.close
    end
  end

  class ObjectSink
    def initialize(expected_count)
      @expected_count = expected_count
      @semaphore = Concurrent::Semaphore.new(expected_count)
      @semaphore.acquire(expected_count)
      @received = []
    end

    def <<(value)
      @received << value
      @semaphore.release(1)
    end

    def await_values
      @semaphore.acquire(@expected_count)
      @received
    end
  end

  it "sends expected headers" do
    with_server do |server|
      connected = Concurrent::Event.new
      received_req = nil
      server.setup_response("/") do |req,res|
        received_req = req
        res.content_type = "text/event-stream"
        res.status = 200
        connected.set
      end
      
      headers = {
        "Authorization" => "secret"
      }

      with_client(subject.new(server.base_uri, headers: headers, logger: NullLogger.new)) do |client|
        connected.wait
        expect(received_req).not_to be_nil
        expect(received_req.header).to eq({
          "accept" => ["text/event-stream"],
          "cache-control" => ["no-cache"],
          "host" => ["127.0.0.1"],
          "authorization" => ["secret"]
        })
      end
    end
  end

  it "receives messages" do
    events_body = <<-EOT
event: go
data: foo
id: 1

event: stop
data: bar

EOT

    with_server do |server|
      server.setup_response("/") do |req,res|
        res.content_type = "text/event-stream"
        res.status = 200
        res.body = events_body
      end

      event_sink = ObjectSink.new(2)
      client = subject.new(server.base_uri, logger: NullLogger.new) do |c|
        c.on_event { |event| event_sink << event }
      end

      with_client(client) do |client|
        expect(event_sink.await_values).to eq([
          SSE::SSEEvent.new(:go, "foo", "1"),
          SSE::SSEEvent.new(:stop, "bar", nil)
        ])
      end
    end
  end

  it "reconnects after error response" do
    events_body = <<-EOT
event: go
data: foo

EOT

    with_server do |server|
      attempt = 0
      server.setup_response("/") do |req,res|
        attempt += 1
        if attempt == 1
          res.status = 500
          res.body = "sorry"
          res.keep_alive = false
        else
          res.content_type = "text/event-stream"
          res.status = 200
          res.body = events_body
        end
      end

      event_sink = ObjectSink.new(1)
      error_sink = ObjectSink.new(1)
      client = subject.new(server.base_uri,
          reconnect_time: 0.25, logger: NullLogger.new) do |c|
        c.on_event { |event| event_sink << event }
        c.on_error { |error| error_sink << error }
      end

      with_client(client) do |client|
        expect(event_sink.await_values).to eq([
          SSE::SSEEvent.new(:go, "foo", nil)
        ])
        expect(error_sink.await_values).to eq([
          { status_code: 500, body: "sorry" }
        ])
        expect(attempt).to eq(2)
      end
    end
  end

  it "reconnects after read timeout" do
    events_body = <<-EOT
event: go
data: foo

EOT

    with_server do |server|
      attempt = 0
      server.setup_response("/") do |req,res|
        attempt += 1
        if attempt == 1
          sleep(2)
        end
        res.content_type = "text/event-stream"
        res.status = 200
        res.body = events_body
      end

      event_sink = ObjectSink.new(1)
      client = subject.new(server.base_uri,
          reconnect_time: 0.25, read_timeout: 0.25, logger: NullLogger.new) do |c|
        c.on_event { |event| event_sink << event }
      end

      with_client(client) do |client|
        expect(event_sink.await_values).to eq([
          SSE::SSEEvent.new(:go, "foo", nil)
        ])
        expect(attempt).to eq(2)
      end
    end
  end
end
