require "spec_helper"
require "socketry"
require "sse_client/sse_shared"

#
# End-to-end tests of HTTP requests against a real server
#
describe SSE::StreamingHTTPConnection do
  subject { SSE::StreamingHTTPConnection }

  def with_connection(cxn)
    begin
      yield cxn
    ensure
      cxn.close
    end
  end

  it "makes HTTP connection and sends request" do
    with_server do |server|
      requests = Queue.new
      server.setup_response("/foo") do |req,res|
        requests << req
        res.status = 200
      end
      headers = {
        "Accept" => "text/plain"
      }
      with_connection(subject.new(server.base_uri.merge("/foo?bar"), nil, headers, 30, 30)) do
        received_req = requests.pop
        expect(received_req.unparsed_uri).to eq("/foo?bar")
        expect(received_req.header).to eq({ "accept" => ["text/plain"] })
      end
    end
  end

  it "receives response status" do
    with_server do |server|
      server.setup_response("/foo") do |req,res|
        res.status = 204
      end
      with_connection(subject.new(server.base_uri.merge("/foo"), nil, {}, 30, 30)) do |cxn|
        expect(cxn.status).to eq(204)
      end
    end
  end

  it "receives response headers" do
    with_server do |server|
      server.setup_response("/foo") do |req,res|
        res["Content-Type"] = "application/json"
      end
      with_connection(subject.new(server.base_uri.merge("/foo"), nil, {}, 30, 30)) do |cxn|
        expect(cxn.headers["content-type"]).to eq("application/json")
      end
    end
  end

  it "can read response as lines" do
    body = <<-EOT
This is
a response
EOT
    with_server do |server|
      server.setup_response("/foo") do |req,res|
        res.body = body
      end
      with_connection(subject.new(server.base_uri.merge("/foo"), nil, {}, 30, 30)) do |cxn|
        lines = cxn.read_lines
        expect(lines.next).to eq("This is\n")
        expect(lines.next).to eq("a response\n")
      end
    end
  end

  it "can read entire response body" do
    body = <<-EOT
This is
a response
EOT
    with_server do |server|
      server.setup_response("/foo") do |req,res|
        res.body = body
      end
      with_connection(subject.new(server.base_uri.merge("/foo"), nil, {}, 30, 30)) do |cxn|
        read_body = cxn.read_all
        expect(read_body).to eq("This is\na response\n")
      end
    end
  end

  it "enforces read timeout" do
    with_server do |server|
      server.setup_response("/") do |req,res|
        sleep(2)
        res.status = 200
      end
      expect { subject.new(server.base_uri, nil, {}, 30, 0.25) }.to raise_error(Socketry::TimeoutError)
    end
  end

  it "connects to HTTP server through proxy" do
    body = "hi"
    with_server do |server|
      server.setup_response("/foo") do |req,res|
        res.body = body
      end
      with_server(StubProxyServer.new) do |proxy|
        with_connection(subject.new(server.base_uri.merge("/foo"), proxy.base_uri, {}, 30, 30)) do |cxn|
          read_body = cxn.read_all
          expect(read_body).to eq("hi")
          expect(proxy.request_count).to eq(1)
        end
      end
    end
  end

  it "connects to HTTPS server through proxy" do
    body = "hi"
    with_server(StubSecureHTTPServer.new) do |server|
      server.setup_response("/foo") do |req,res|
        res.body = body
      end
      with_server(StubProxyServer.new) do |proxy|
        with_connection(subject.new(server.base_uri.merge("/foo"), proxy.base_uri, {}, 30, 30)) do |cxn|
          read_body = cxn.read_all
          expect(read_body).to eq("hi")
          expect(proxy.request_count).to eq(1)
        end
      end
    end
  end
end

#
# Tests of response parsing functionality without a real HTTP request
#
describe SSE::HTTPResponseReader do
  subject { SSE::HTTPResponseReader }

  let(:simple_response) { <<-EOT
HTTP/1.1 200 OK
Cache-Control: no-cache
Content-Type: text/event-stream

line1\r
line2
\r
EOT
  }

  def make_chunks(str)
    # arbitrarily split content into 5-character blocks
    str.scan(/.{1,5}/m).to_enum
  end

  def mock_socket_without_timeout(chunks)
    mock_socket(chunks) { :eof }
  end

  def mock_socket_with_timeout(chunks)
    mock_socket(chunks) { raise Socketry::TimeoutError }
  end

  def mock_socket(chunks)
    sock = double
    allow(sock).to receive(:readpartial) do
      begin
        chunks.next
      rescue StopIteration
        yield
      end
    end
    sock
  end

  it "parses status code" do
    socket = mock_socket_without_timeout(make_chunks(simple_response))
    reader = subject.new(socket, 0)
    expect(reader.status).to eq(200)
  end

  it "parses headers" do
    socket = mock_socket_without_timeout(make_chunks(simple_response))
    reader = subject.new(socket, 0)
    expect(reader.headers).to eq({
      'cache-control' => 'no-cache',
      'content-type' => 'text/event-stream'
    })
  end

  it "can read entire response body" do
    socket = mock_socket_without_timeout(make_chunks(simple_response))
    reader = subject.new(socket, 0)
    expect(reader.read_all).to eq("line1\r\nline2\n\r\n")
  end

  it "can read response body as lines" do
    socket = mock_socket_without_timeout(make_chunks(simple_response))
    reader = subject.new(socket, 0)
    expect(reader.read_lines.to_a).to eq([
      "line1\r\n",
      "line2\n",
      "\r\n"
    ])
  end

  it "handles chunked encoding" do
    chunked_response = <<-EOT
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked

6\r
things\r
A\r
 and stuff\r
0\r
\r
EOT
    socket = mock_socket_without_timeout(make_chunks(chunked_response))
    reader = subject.new(socket, 0)
    expect(reader.read_all).to eq("things and stuff")
  end

  it "raises error if response ends without complete headers" do
    malformed_response = <<-EOT
HTTP/1.1 200 OK
Cache-Control: no-cache
EOT
    socket = mock_socket_without_timeout(make_chunks(malformed_response))
    expect { subject.new(socket, 0) }.to raise_error(EOFError)
  end

  it "throws timeout if thrown by socket read" do
    socket = mock_socket_with_timeout(make_chunks(simple_response))
    reader = subject.new(socket, 0)
    lines = reader.read_lines
    lines.next
    lines.next
    lines.next
    expect { lines.next }.to raise_error(Socketry::TimeoutError)
  end
end
