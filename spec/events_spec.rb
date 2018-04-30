require "spec_helper"
require "faraday"
require "time"

describe LaunchDarkly::EventProcessor do
  subject { LaunchDarkly::EventProcessor }

  let(:default_config) { LaunchDarkly::Config.new }
  let(:hc) { FakeHttpClient.new }
  let(:user) { { key: "userkey", name: "Red" } }
  let(:filtered_user) { { key: "userkey", privateAttrs: [ "name" ] } }

  after(:each) do
    if !@ep.nil?
      @ep.stop
    end
  end

  it "queues identify event" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = { kind: "identify", key: user[:key], user: user }
    @ep.add_event(e)

    output = flush_and_get_events
    expect(output).to contain_exactly(e)
  end

  it "filters user in identify event" do
    config = LaunchDarkly::Config.new(all_attributes_private: true)
    @ep = subject.new("sdk_key", config, hc)
    e = { kind: "identify", key: user[:key], user: user }
    @ep.add_event(e)

    output = flush_and_get_events
    expect(output).to contain_exactly({
      kind: "identify",
      key: user[:key],
      creationDate: e[:creationDate],
      user: filtered_user
    })
  end

  it "queues individual feature event with index event" do
    @ep = subject.new("sdk_key", default_config, hc)
    flag = { key: "flagkey", version: 11 }
    fe = {
      kind: "feature", key: "flagkey", version: 11, user: user,
      variation: 1, value: "value", trackEvents: true
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe, user)),
      eq(feature_event(fe, flag, false, nil)),
      include(:kind => "summary")
    )
  end

  it "filters user in index event" do
    config = LaunchDarkly::Config.new(all_attributes_private: true)
    @ep = subject.new("sdk_key", config, hc)
    flag = { key: "flagkey", version: 11 }
    fe = {
      kind: "feature", key: "flagkey", version: 11, user: user,
      variation: 1, value: "value", trackEvents: true
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe, filtered_user)),
      eq(feature_event(fe, flag, false, nil)),
      include(:kind => "summary")
    )
  end

  it "can include inline user in feature event" do
    config = LaunchDarkly::Config.new(inline_users_in_events: true)
    @ep = subject.new("sdk_key", config, hc)
    flag = { key: "flagkey", version: 11 }
    fe = {
      kind: "feature", key: "flagkey", version: 11, user: user,
      variation: 1, value: "value", trackEvents: true
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(feature_event(fe, flag, false, user)),
      include(:kind => "summary")
    )
  end

  it "filters user in feature event" do
    config = LaunchDarkly::Config.new(all_attributes_private: true, inline_users_in_events: true)
    @ep = subject.new("sdk_key", config, hc)
    flag = { key: "flagkey", version: 11 }
    fe = {
      kind: "feature", key: "flagkey", version: 11, user: user,
      variation: 1, value: "value", trackEvents: true
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(feature_event(fe, flag, false, filtered_user)),
      include(:kind => "summary")
    )
  end

  it "still generates index event if inline_users is true but feature event was not tracked" do
    config = LaunchDarkly::Config.new(inline_users_in_events: true)
    @ep = subject.new("sdk_key", config, hc)
    flag = { key: "flagkey", version: 11 }
    fe = {
      kind: "feature", key: "flagkey", version: 11, user: user,
      variation: 1, value: "value", trackEvents: false
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe, user)),
      include(:kind => "summary")
    )
  end

  it "sets event kind to debug if flag is temporarily in debug mode" do
    @ep = subject.new("sdk_key", default_config, hc)
    flag = { key: "flagkey", version: 11 }
    future_time = (Time.now.to_f * 1000).to_i + 1000000
    fe = {
      kind: "feature", key: "flagkey", version: 11, user: user,
      variation: 1, value: "value", trackEvents: false, debugEventsUntilDate: future_time
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe, user)),
      eq(feature_event(fe, flag, true, user)),
      include(:kind => "summary")
    )
  end

  it "can be both debugging and tracking an event" do
    @ep = subject.new("sdk_key", default_config, hc)
    flag = { key: "flagkey", version: 11 }
    future_time = (Time.now.to_f * 1000).to_i + 1000000
    fe = {
      kind: "feature", key: "flagkey", version: 11, user: user,
      variation: 1, value: "value", trackEvents: true, debugEventsUntilDate: future_time
    }
    @ep.add_event(fe)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe, user)),
      eq(feature_event(fe, flag, false, nil)),
      eq(feature_event(fe, flag, true, user)),
      include(:kind => "summary")
    )
  end

  it "ends debug mode based on client time if client time is later than server time" do
    @ep = subject.new("sdk_key", default_config, hc)

    # Pick a server time that is somewhat behind the client time
    server_time = (Time.now.to_f * 1000).to_i - 20000

    # Send and flush an event we don't care about, just to set the last server time
    hc.set_server_time(server_time)
    @ep.add_event({ kind: "identify", user: { key: "otherUser" }})
    flush_and_get_events

    # Now send an event with debug mode on, with a "debug until" time that is further in
    # the future than the server time, but in the past compared to the client.
    flag = { key: "flagkey", version: 11 }
    debug_until = server_time + 1000
    fe = {
      kind: "feature", key: "flagkey", version: 11, user: user,
      variation: 1, value: "value", trackEvents: false, debugEventsUntilDate: debug_until
    }
    @ep.add_event(fe)

    # Should get a summary event only, not a full feature event
    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe, user)),
      include(:kind => "summary")
    )
  end

  it "ends debug mode based on server time if server time is later than client time" do
    @ep = subject.new("sdk_key", default_config, hc)

    # Pick a server time that is somewhat ahead of the client time
    server_time = (Time.now.to_f * 1000).to_i + 20000

    # Send and flush an event we don't care about, just to set the last server time
    hc.set_server_time(server_time)
    @ep.add_event({ kind: "identify", user: { key: "otherUser" }})
    flush_and_get_events

    # Now send an event with debug mode on, with a "debug until" time that is further in
    # the future than the server time, but in the past compared to the client.
    flag = { key: "flagkey", version: 11 }
    debug_until = server_time - 1000
    fe = {
      kind: "feature", key: "flagkey", version: 11, user: user,
      variation: 1, value: "value", trackEvents: false, debugEventsUntilDate: debug_until
    }
    @ep.add_event(fe)

    # Should get a summary event only, not a full feature event
    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe, user)),
      include(:kind => "summary")
    )
  end

  it "generates only one index event for multiple events with same user" do
    @ep = subject.new("sdk_key", default_config, hc)
    flag1 = { key: "flagkey1", version: 11 }
    flag2 = { key: "flagkey2", version: 22 }
    future_time = (Time.now.to_f * 1000).to_i + 1000000
    fe1 = {
      kind: "feature", key: "flagkey1", version: 11, user: user,
      variation: 1, value: "value", trackEvents: true
    }
    fe2 = {
      kind: "feature", key: "flagkey2", version: 22, user: user,
      variation: 1, value: "value", trackEvents: true
    }
    @ep.add_event(fe1)
    @ep.add_event(fe2)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe1, user)),
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
      kind: "feature", key: "flagkey1", version: 11, user: user,
      variation: 1, value: "value1", default: "default1"
    }
    fe2 = {
      kind: "feature", key: "flagkey2", version: 22, user: user,
      variation: 2, value: "value2", default: "default2"
    }
    @ep.add_event(fe1)
    @ep.add_event(fe2)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(fe1, user)),
      eq({
        kind: "summary",
        startDate: fe1[:creationDate],
        endDate: fe2[:creationDate],
        features: {
          flagkey1: {
            default: "default1",
            counters: [
              { version: 11, variation: 1, value: "value1", count: 1 }
            ]
          },
          flagkey2: {
            default: "default2",
            counters: [
              { version: 22, variation: 2, value: "value2", count: 1 }
            ]
          }
        }
      })
    )
  end

  it "queues custom event with user" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = { kind: "custom", key: "eventkey", user: user, data: { thing: "stuff" } }
    @ep.add_event(e)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(index_event(e, user)),
      eq(custom_event(e, nil))
    )
  end

  it "can include inline user in custom event" do
    config = LaunchDarkly::Config.new(inline_users_in_events: true)
    @ep = subject.new("sdk_key", config, hc)
    e = { kind: "custom", key: "eventkey", user: user, data: { thing: "stuff" } }
    @ep.add_event(e)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(custom_event(e, user))
    )
  end

  it "filters user in custom event" do
    config = LaunchDarkly::Config.new(all_attributes_private: true, inline_users_in_events: true)
    @ep = subject.new("sdk_key", config, hc)
    e = { kind: "custom", key: "eventkey", user: user, data: { thing: "stuff" } }
    @ep.add_event(e)

    output = flush_and_get_events
    expect(output).to contain_exactly(
      eq(custom_event(e, filtered_user))
    )
  end

  it "does a final flush when shutting down" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = { kind: "identify", key: user[:key], user: user }
    @ep.add_event(e)
    
    @ep.stop

    output = get_events_from_last_request
    expect(output).to contain_exactly(e)
  end

  it "sends nothing if there are no events" do
    @ep = subject.new("sdk_key", default_config, hc)
    @ep.flush
    expect(hc.get_request).to be nil
  end

  it "sends SDK key" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = { kind: "identify", user: user }
    @ep.add_event(e)

    @ep.flush
    @ep.wait_until_inactive
    
    expect(hc.get_request.headers["Authorization"]).to eq "sdk_key"
  end

  it "stops posting events after getting a 401 error" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = { kind: "identify", user: user }
    @ep.add_event(e)

    hc.set_response_status(401)
    @ep.flush
    @ep.wait_until_inactive
    expect(hc.get_request).not_to be_nil
    hc.reset

    @ep.add_event(e)
    @ep.flush
    @ep.wait_until_inactive
    expect(hc.get_request).to be_nil
  end

  it "retries flush once after 5xx error" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = { kind: "identify", user: user }
    @ep.add_event(e)

    hc.set_response_status(503)
    @ep.flush
    @ep.wait_until_inactive

    expect(hc.get_request).not_to be_nil
    expect(hc.get_request).not_to be_nil
    expect(hc.get_request).to be_nil  # no 3rd request
  end

  it "retries flush once after connection error" do
    @ep = subject.new("sdk_key", default_config, hc)
    e = { kind: "identify", user: user }
    @ep.add_event(e)

    hc.set_exception(Faraday::Error::ConnectionFailed.new("fail"))
    @ep.flush
    @ep.wait_until_inactive

    expect(hc.get_request).not_to be_nil
    expect(hc.get_request).not_to be_nil
    expect(hc.get_request).to be_nil  # no 3rd request
  end

  def index_event(e, user)
    {
      kind: "index",
      creationDate: e[:creationDate],
      user: user
    }
  end

  def feature_event(e, flag, debug, inline_user)
    out = {
      kind: debug ? "debug" : "feature",
      creationDate: e[:creationDate],
      key: flag[:key],
      variation: e[:variation],
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
    @ep.wait_until_inactive
    get_events_from_last_request
  end

  def get_events_from_last_request
    req = hc.get_request
    JSON.parse(req.body, symbolize_names: true)
  end

  class FakeHttpClient
    def initialize
      reset
    end

    def set_response_status(status)
      @status = status
    end

    def set_server_time(time_millis)
      @server_time = Time.at(time_millis.to_f / 1000)
    end

    def set_exception(e)
      @exception = e
    end

    def reset
      @requests = []
      @status = 200
    end

    def post(uri)
      req = Faraday::Request.create("POST")
      req.headers = {}
      req.options = Faraday::RequestOptions.new
      yield req
      @requests.push(req)
      if @exception
        raise @exception
      else
        resp = Faraday::Response.new
        headers = {}
        if @server_time
          headers["Date"] = @server_time.httpdate
        end
        resp.finish({
          status: @status ? @status : 200,
          response_headers: headers
        })
        resp
      end
    end

    def get_request
      @requests.shift
    end
  end

  class FakeResponse
    def initialize(status)
      @status = status
    end

    attr_reader :status
  end
end
