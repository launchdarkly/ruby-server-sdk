require "spec_helper"

describe LaunchDarkly::EventSummarizer do
  subject { LaunchDarkly::EventSummarizer }

  let(:user) { { key: "key" } }

  it "returns false from notice_user for never-seen user" do
    es = subject.new(LaunchDarkly::Config.new)
    expect(es.notice_user(user)).to be false
  end

  it "returns true from notice_user for previously seen user" do
    es = subject.new(LaunchDarkly::Config.new)
    expect(es.notice_user(user)).to be false
    expect(es.notice_user(user)).to be true
  end

  it "discards oldest user if capacity is exceeded" do
    config = LaunchDarkly::Config.new(user_keys_capacity: 2)
    es = subject.new(config)
    user1 = { key: "key1" }
    user2 = { key: "key2" }
    user3 = { key: "key3" }
    expect(es.notice_user(user1)).to be false
    expect(es.notice_user(user2)).to be false
    expect(es.notice_user(user3)).to be false
    expect(es.notice_user(user3)).to be true
    expect(es.notice_user(user2)).to be true
    expect(es.notice_user(user1)).to be false
  end

  it "does not add identify event to summary" do
    es = subject.new(LaunchDarkly::Config.new)
    snapshot = es.snapshot
    es.summarize_event({ kind: "identify", user: user })

    expect(es.snapshot).to eq snapshot
  end

  it "does not add custom event to summary" do
    es = subject.new(LaunchDarkly::Config.new)
    snapshot = es.snapshot
    es.summarize_event({ kind: "custom", key: "whatever", user: user })

    expect(es.snapshot).to eq snapshot
  end

  it "tracks start and end dates" do
    es = subject.new(LaunchDarkly::Config.new)
    flag = { key: "key" }
    event1 = { kind: "feature", creationDate: 2000, user: user }
    event2 = { kind: "feature", creationDate: 1000, user: user }
    event3 = { kind: "feature", creationDate: 1500, user: user }
    es.summarize_event(event1)
    es.summarize_event(event2)
    es.summarize_event(event3)
    data = es.output(es.snapshot)

    expect(data[:startDate]).to be 1000
    expect(data[:endDate]).to be 2000
  end

  it "counts events" do
    es = subject.new(LaunchDarkly::Config.new)
    flag1 = { key: "key1", version: 11 }
    flag2 = { key: "key2", version: 22 }
    event1 = { kind: "feature", key: "key1", version: 11, user: user, variation: 1, value: "value1", default: "default1" }
    event2 = { kind: "feature", key: "key1", version: 11, user: user, variation: 2, value: "value2", default: "default1" }
    event3 = { kind: "feature", key: "key2", version: 22, user: user, variation: 1, value: "value99", default: "default2" }
    event4 = { kind: "feature", key: "key1", version: 11, user: user, variation: 1, value: "value1", default: "default1" }
    event5 = { kind: "feature", key: "badkey", user: user, variation: nil, value: "default3", default: "default3" }
    [event1, event2, event3, event4, event5].each { |e| es.summarize_event(e) }
    data = es.output(es.snapshot)

    data[:features]["key1"][:counters].sort! { |a, b| a[:value] <=> b[:value] }
    expectedFeatures = {
      "key1" => {
        default: "default1",
        counters: [
          { value: "value1", version: 11, count: 2 },
          { value: "value2", version: 11, count: 1 }
        ]
      },
      "key2" => {
        default: "default2",
        counters: [
          { value: "value99", version: 22, count: 1 }
        ]
      },
      "badkey" => {
        default: "default3",
        counters: [
          { value: "default3", unknown: true, count: 1 }
        ]
      }
    }
    expect(data[:features]).to eq expectedFeatures
  end
end
