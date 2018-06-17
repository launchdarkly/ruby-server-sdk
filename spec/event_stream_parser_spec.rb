require "spec_helper"

describe LaunchDarkly::EventStreamParser do
  subject { described_class }

  it "converts lines to events" do
    lines =  <<LINES
id: 123
event: my-event
data: my-data

LINES
    event_stream_parser = subject.new ->(r) {}
    events = []
    event_stream_parser.parse_chunk(lines) do |evt|
      events << evt
    end
    expect(events.length).to eq 1
    expect(events[0].id).to eq "123"
    expect(events[0].type).to eq "my-event".to_sym
    expect(events[0].data).to eq "my-data"
  end

  it "ignores comments" do
    lines =  <<LINES
: comment
id: 123
event: my-event
data: my-data


LINES
    event_stream_parser = subject.new ->(r) {}
    events = []
    event_stream_parser.parse_chunk(lines) do |evt|
      events << evt
    end
    expect(events.length).to eq 1
    expect(events[0].id).to eq "123"
  end

  it "resets values after each event" do
    lines =  <<LINES
id: 123
event: my-event
data: my-data

event: my-event2
data: my-data2

LINES
    event_stream_parser = subject.new ->(r) {}
    events = []
    event_stream_parser.parse_chunk(lines) do |evt|
      events << evt
    end
    expect(events.length).to eq 2
    expect(events[0].id).to eq "123"
    expect(events[0].type).to eq "my-event".to_sym
    expect(events[0].data).to eq "my-data"
    expect(events[1].id).to eq ""
    expect(events[1].type).to eq "my-event2".to_sym
    expect(events[1].data).to eq "my-data2"
  end

  it "sets the default event type to message" do
    lines =  <<LINES
data: my-data

LINES
    event_stream_parser = subject.new ->(r) {}
    events = []
    event_stream_parser.parse_chunk(lines) do |evt|
      events << evt
    end
    expect(events.length).to eq 1
    expect(events[0].id).to eq ""
    expect(events[0].type).to eq :message
    expect(events[0].data).to eq "my-data"
  end

  it "does not generate events unless data is provided" do
    lines =  <<LINES
id: 123
event: my-event

LINES
    event_stream_parser = subject.new ->(r) {}
    events = []
    event_stream_parser.parse_chunk(lines) do |evt|
      events << evt
    end
    expect(events.length).to eq 0
  end

  it "reads correctly partial data" do
    first_partial_read = "id: 123\ndata: my-da"
    second_partial_read = <<SECOND_LINES
ta
data: my-other-data

SECOND_LINES
    event_stream_parser = subject.new ->(r) {}
    events = []
    event_stream_parser.parse_chunk(first_partial_read) do |evt|
      events << evt
    end
    event_stream_parser.parse_chunk(second_partial_read) do |evt|
      events << evt
    end
    expect(events.length).to eq 1
    expect(events[0].id).to eq "123"
    expect(events[0].type).to eq :message
    expect(events[0].data).to eq "my-data\nmy-other-data"
  end

  it "reports retry updates to the provided function" do
    lines =  <<LINES
retry: 123
retry: 456
LINES
    received_retry_args = []
    event_stream_parser = subject.new ->(timeout) { received_retry_args << timeout }
    events = []
    event_stream_parser.parse_chunk(lines) do |evt|
      events << evt
    end
    expect(received_retry_args).to eq [123, 456]
    expect(events.length).to eq 0
  end
end
