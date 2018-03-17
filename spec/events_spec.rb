require "spec_helper"
require "faraday"
require "time"

describe LaunchDarkly::EventProcessor do
  subject { LaunchDarkly::EventProcessor }

  let(:default_config) { LaunchDarkly::Config.new }
  let(:hc) { FakeHttpClient.new }
  let(:user) { { key: "userkey", name: "Red" } }

  after(:each) do
    if !@ep.nil?
      @ep.stop
    end
  end

  it "queues identify event" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = {
      kind: "identify",
      user: user
    }
    @ep.add_event(e)

    output = flush_and_get_events
    expect(output).to contain_exactly(e)
  end

  it "queues individual feature event with index event" do
    @ep = subject.new("sdk_key", default_config, hc)
    flag = { key: "flagkey", version: 11 }
    fe = {
      kind: "feature",
      key: "flagkey",
      version: 11,
      user: user,
      variation: 1,
      value: "value",
      trackEvents: true
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe)),
      eq(feature_event(fe, flag, false, nil)),
      include(:kind => "summary")
    )
  end

  it "can include inline user in feature event" do
    config = LaunchDarkly::Config.new(inline_users_in_events: true)
    @ep = subject.new("sdk_key", config, hc)
    flag = { key: "flagkey", version: 11 }
    fe = {
      kind: "feature",
      key: "flagkey",
      version: 11,
      user: user,
      variation: 1,
      value: "value",
      trackEvents: true
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(feature_event(fe, flag, false, user)),
      include(:kind => "summary")
    )
  end

  it "sets event kind to debug if flag is temporarily in debug mode" do
    @ep = subject.new("sdk_key", default_config, hc)
    flag = { key: "flagkey", version: 11 }
    future_time = (Time.now.to_f * 1000).to_i + 1000000
    fe = {
      kind: "feature",
      key: "flagkey",
      version: 11,
      user: user,
      variation: 1,
      value: "value",
      debugEventsUntilDate: future_time
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe)),
      eq(feature_event(fe, flag, true, nil)),
      include(:kind => "summary")
    )
  end

  it "generates only one index event for multiple events with same user" do
    @ep = subject.new("sdk_key", default_config, hc)
    flag1 = { key: "flagkey1", version: 11 }
    flag2 = { key: "flagkey2", version: 22 }
    future_time = (Time.now.to_f * 1000).to_i + 1000000
    fe1 = {
      kind: "feature",
      key: "flagkey1",
      version: 11,
      user: user,
      variation: 1,
      value: "value",
      trackEvents: true
    }
    fe2 = {
      kind: "feature",
      key: "flagkey2",
      version: 22,
      user: user,
      variation: 1,
      value: "value",
      trackEvents: true
    }
    @ep.add_event(fe1)
    @ep.add_event(fe2)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe1)),
      eq(feature_event(fe1, flag1, false, nil)),
      eq(feature_event(fe2, flag2, false, nil)),
      include(:kind => "summary")
    )
  end

  it "summarizes non-tracked events" do
    @ep = subject.new("sdk_key", default_config, hc)
    flag1 = { key: "flagkey1", version: 11 }
    flag2 = { key: "flagkey2", version: 22 }
    future_time = (Time.now.to_f * 1000).to_i + 1000000
    fe1 = {
      kind: "feature",
      key: "flagkey1",
      version: 11,
      user: user,
      variation: 1,
      value: "value1",
      default: "default1"
    }
    fe2 = {
      kind: "feature",
      key: "flagkey2",
      version: 22,
      user: user,
      variation: 1,
      value: "value2",
      default: "default2"
    }
    @ep.add_event(fe1)
    @ep.add_event(fe2)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe1)),
      eq({
        kind: "summary",
        startDate: fe1[:creationDate],
        endDate: fe2[:creationDate],
        features: {
          flagkey1: {
            default: "default1",
            counters: [
              { version: 11, value: "value1", count: 1 }
            ]
          },
          flagkey2: {
            default: "default2",
            counters: [
              { version: 22, value: "value2", count: 1 }
            ]
          }
        }
      })
    )
  end

  it "queues custom event with user" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = {
      kind: "custom",
      key: "eventkey",
      user: user,
      data: { thing: "stuff" }
    }
    @ep.add_event(e)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(e)),
      eq(custom_event(e, nil))
    )
  end

  it "can include inline user in custom event" do
    config = LaunchDarkly::Config.new(inline_users_in_events: true)
    @ep = subject.new("sdk_key", config, hc)
    e = {
      kind: "custom",
      key: "eventkey",
      user: user,
      data: { thing: "stuff" }
    }
    @ep.add_event(e)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(custom_event(e, user))
    )
  end

  it "sends nothing if there are no events" do
    @ep = subject.new("sdk_key", default_config, hc)
    @ep.flush
    expect(hc.request_received).to be nil
  end

  it "sends SDK key" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = {
      kind: "identify",
      user: user
    }
    @ep.add_event(e)

    flush_and_get_events
    expect(hc.request_received.headers["Authorization"]).to eq "sdk_key"
  end

  def index_event(e)
    {
      kind: "index",
      creationDate: e[:creationDate],
      user: e[:user]
    }
  end

  def feature_event(e, flag, debug, inline_user)
    out = {
      kind: debug ? "debug" : "feature",
      creationDate: e[:creationDate],
      key: flag[:key],
      version: flag[:version],
      value: e[:value]
    }
    if inline_user.nil?
      out[:userKey] = e[:user][:key]
    else
      out[:user] = inline_user
    end
    out
  end

  def custom_event(e, inline_user)
    out = {
      kind: "custom",
      creationDate: e[:creationDate],
      key: e[:key]
    }
    out[:data] = e[:data] if e.has_key?(:data)
    if inline_user.nil?
      out[:userKey] = e[:user][:key]
    else
      out[:user] = inline_user
    end
    out
  end

  def flush_and_get_events
    @ep.flush
    req = hc.request_received
    JSON.parse(req.body, symbolize_names: true)
  end

  class FakeHttpClient
    def post(uri)
      req = Faraday::Request.create("POST")
      req.headers = {}
      req.options = Faraday::RequestOptions.new
      yield req
      @request_received = req
      resp = Faraday::Response.new
      resp.finish({
        status: 200,
        response_headers: {
          Date: Time.now.httpdate
        }
      })
      resp
    end

    attr_reader :request_received
  end

  class FakeResponse
    def initialize(status)
      @status = status
    end

    attr_reader :status
  end
end
