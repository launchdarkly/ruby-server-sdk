require "spec_helper"

describe LaunchDarkly::EventSummarizer do
  subject { LaunchDarkly::EventSummarizer }

  let(:user) { { key: "key" } }

  it "does not add identify event to summary" do
    es = subject.new
    snapshot = es.snapshot
    es.summarize_event({ kind: "identify", user: user })

    expect(es.snapshot).to eq snapshot
  end

  it "does not add custom event to summary" do
    es = subject.new
    snapshot = es.snapshot
    es.summarize_event({ kind: "custom", key: "whatever", user: user })

    expect(es.snapshot).to eq snapshot
  end

  it "tracks start and end dates" do
    es = subject.new
    flag = { key: "key" }
    event1 = { kind: "feature", creationDate: 2000, user: user }
    event2 = { kind: "feature", creationDate: 1000, user: user }
    event3 = { kind: "feature", creationDate: 1500, user: user }
    es.summarize_event(event1)
    es.summarize_event(event2)
    es.summarize_event(event3)
    data = es.snapshot

    expect(data.start_date).to be 1000
    expect(data.end_date).to be 2000
  end

  it "counts events" do
    es = subject.new
    flag1 = { key: "key1", version: 11 }
    flag2 = { key: "key2", version: 22 }
    event1 = { kind: "feature", key: "key1", version: 11, user: user, variation: 1, value: "value1", default: "default1" }
    event2 = { kind: "feature", key: "key1", version: 11, user: user, variation: 2, value: "value2", default: "default1" }
    event3 = { kind: "feature", key: "key2", version: 22, user: user, variation: 1, value: "value99", default: "default2" }
    event4 = { kind: "feature", key: "key1", version: 11, user: user, variation: 1, value: "value1", default: "default1" }
    event5 = { kind: "feature", key: "badkey", user: user, variation: nil, value: "default3", default: "default3" }
    [event1, event2, event3, event4, event5].each { |e| es.summarize_event(e) }
    data = es.snapshot

    expectedCounters = {
      { key: "key1", version: 11, variation: 1 } =>
        { count: 2, value: "value1", default: "default1" },
      { key: "key1", version: 11, variation: 2 } =>
        { count: 1, value: "value2", default: "default1" },
      { key: "key2", version: 22, variation: 1 } =>
        { count: 1, value: "value99", default: "default2" },
      { key: "badkey", version: nil, variation: nil } =>
        { count: 1, value: "default3", default: "default3" }
    }
    expect(data.counters).to eq expectedCounters
  end
end
