require 'spec_helper'

describe LaunchDarkly::EventStreamParser do
  it 'emits events regardless of the input chunking' do
    expect(subject).not_to be_pending

    subject << 'data'
    expect(subject).to be_pending

    subject << ':' << ' foobar' << "\n\n"
    expect(subject).not_to be_pending

    events = subject.take_events
    expect(events.length).to eq(1)

    first_event = events.first
    expect(first_event.retry).to be_nil
    expect(first_event.type).to be_nil
    expect(first_event.data).to eq("foobar\n")

    expect(subject.take_events).to be_empty
  end

  it 'is able to parse the example event stream file regardless of chunk composition' do
    # In practice, event streams make use of the chunked transfer encoding. They are then
    # further broken down using linefeed characters within the event stream. Therefore, there
    # is no guarantee that the chunking applied by the transfer-encoding is going to fall
    # on the boundaries within the event stream, so we have to be prepared to receive
    # these chunks in random order. Moreover, we have to accept these chunks as bytes
    # - as binary, because there is no guarantee that the chunk boundaries are going
    # to honor the grouping of bytes within a single UTF-8 codepoint. And the event stream
    # spec mandates UTF-8 for everything.
    file_buf = File.open(File.dirname(__FILE__) + '/fixtures/sample_eventstream.txt', 'rb')
    5.times do
      file_buf.rewind
      until file_buf.eof?
        n_read = rand(1..48)
        subject << file_buf.read(n_read)
      end
      expect(subject).not_to be_pending
      evts = subject.take_events
      expect(evts.length).to eq(4)

      first_evt = evts.first
      expect(first_evt.id).to be_nil
      expect(first_evt.type).to eq('attach')
      expect(first_evt.data).to eq("{hello: 1}\n")
    end
  end

  it 'recovers only one event ID' do
    evt = subject.parse_event(["id: 123", "id:456", "id:  xyz"].join("\n"))
    expect(evt.id).to eq("xyz")
  end

  it 'recovers only one event type' do
    evt = subject.parse_event(["event: hello", "event:goodbye"].join("\n"))
    expect(evt.type).to eq("goodbye")
  end

  it 'recovers all the event data spanning multiple lines' do
    evt = subject.parse_event(["data: YHOO", "data: +2", "data: 10"].join("\n"))
    expect(evt.data).to eq("YHOO\n+2\n10\n")
  end

  it 'recovers only one retry value, as an integer' do
    evt = subject.parse_event(["retry: 12345", "retry: 78869"].join("\n"))
    expect(evt.retry).to eq(78869)
  end

  it 'is able to parse a complete event' do
    evt = subject.parse_event(["id: abcd", "data: ohai", "event: party", "retry:5"].join("\n"))
    expect(evt.retry).to eq(5)
    expect(evt.type).to eq('party')
    expect(evt.data).to eq("ohai\n")
  end
end
