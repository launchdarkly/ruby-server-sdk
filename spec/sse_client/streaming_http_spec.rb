require "spec_helper"
require "socketry"

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

  let(:malformed_response) { <<-EOT
HTTP/1.1 200 OK
Cache-Control: no-cache
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

  it "raises error if response ends without complete headers" do
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
