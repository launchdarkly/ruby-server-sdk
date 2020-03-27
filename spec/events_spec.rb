require "http_util"
require "spec_helper"
require "time"

describe LaunchDarkly::EventProcessor do
  subject { LaunchDarkly::EventProcessor }

  let(:default_config_opts) { { diagnostic_opt_out: true, logger: $null_log } }
  let(:default_config) { LaunchDarkly::Config.new(default_config_opts) }
  let(:user) { { key: "userkey", name: "Red" } }
  let(:filtered_user) { { key: "userkey", privateAttrs: [ "name" ] } }
  let(:numeric_user) { { key: 1, secondary: 2, ip: 3, country: 4, email: 5, firstName: 6, lastName: 7,
    avatar: 8, name: 9, anonymous: false, custom: { age: 99 } } }
  let(:stringified_numeric_user) { { key: '1', secondary: '2', ip: '3', country: '4', email: '5', firstName: '6',
    lastName: '7', avatar: '8', name: '9', anonymous: false, custom: { age: 99 } } }

  def with_processor_and_sender(config)
    sender = FakeEventSender.new
    ep = subject.new("sdk_key", config, nil, nil, { event_sender: sender })
    begin
      yield ep, sender
    ensure
      ep.stop
    end
  end

  it "queues identify event" do
    with_processor_and_sender(default_config) do |ep, sender|
      e = { kind: "identify", key: user[:key], user: user }
      ep.add_event(e)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(e)
    end
  end

  it "filters user in identify event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(all_attributes_private: true))
    with_processor_and_sender(config) do |ep, sender|
      e = { kind: "identify", key: user[:key], user: user }
      ep.add_event(e)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly({
        kind: "identify",
        key: user[:key],
        creationDate: e[:creationDate],
        user: filtered_user
      })
    end
  end

  it "stringifies built-in user attributes in identify event" do
    with_processor_and_sender(default_config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      e = { kind: "identify", key: numeric_user[:key], user: numeric_user }
      ep.add_event(e)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        kind: "identify",
        key: numeric_user[:key].to_s,
        creationDate: e[:creationDate],
        user: stringified_numeric_user
      )
    end
  end

  it "queues individual feature event with index event" do
    with_processor_and_sender(default_config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: user,
        variation: 1, value: "value", trackEvents: true
      }
      ep.add_event(fe)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(fe, user)),
        eq(feature_event(fe, flag, false, nil)),
        include(:kind => "summary")
      )
    end
  end

  it "filters user in index event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(all_attributes_private: true))
    with_processor_and_sender(config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: user,
        variation: 1, value: "value", trackEvents: true
      }
      ep.add_event(fe)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(fe, filtered_user)),
        eq(feature_event(fe, flag, false, nil)),
        include(:kind => "summary")
      )
    end
  end

  it "stringifies built-in user attributes in index event" do
    with_processor_and_sender(default_config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: numeric_user,
        variation: 1, value: "value", trackEvents: true
      }
      ep.add_event(fe)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(fe, stringified_numeric_user)),
        eq(feature_event(fe, flag, false, nil)),
        include(:kind => "summary")
      )
    end
  end

  it "can include inline user in feature event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(inline_users_in_events: true))
    with_processor_and_sender(config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: user,
        variation: 1, value: "value", trackEvents: true
      }
      ep.add_event(fe)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(feature_event(fe, flag, false, user)),
        include(:kind => "summary")
      )
    end
  end

  it "stringifies built-in user attributes in feature event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(inline_users_in_events: true))
    with_processor_and_sender(config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: numeric_user,
        variation: 1, value: "value", trackEvents: true
      }
      ep.add_event(fe)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(feature_event(fe, flag, false, stringified_numeric_user)),
        include(:kind => "summary")
      )
    end
  end

  it "filters user in feature event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(all_attributes_private: true, inline_users_in_events: true))
    with_processor_and_sender(config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: user,
        variation: 1, value: "value", trackEvents: true
      }
      ep.add_event(fe)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(feature_event(fe, flag, false, filtered_user)),
        include(:kind => "summary")
      )
    end
  end

  it "still generates index event if inline_users is true but feature event was not tracked" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(inline_users_in_events: true))
    with_processor_and_sender(config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: user,
        variation: 1, value: "value", trackEvents: false
      }
      ep.add_event(fe)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(fe, user)),
        include(:kind => "summary")
      )
    end
  end

  it "sets event kind to debug if flag is temporarily in debug mode" do
    with_processor_and_sender(default_config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      future_time = (Time.now.to_f * 1000).to_i + 1000000
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: user,
        variation: 1, value: "value", trackEvents: false, debugEventsUntilDate: future_time
      }
      ep.add_event(fe)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(fe, user)),
        eq(feature_event(fe, flag, true, user)),
        include(:kind => "summary")
      )
    end
  end

  it "can be both debugging and tracking an event" do
    with_processor_and_sender(default_config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      future_time = (Time.now.to_f * 1000).to_i + 1000000
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: user,
        variation: 1, value: "value", trackEvents: true, debugEventsUntilDate: future_time
      }
      ep.add_event(fe)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(fe, user)),
        eq(feature_event(fe, flag, false, nil)),
        eq(feature_event(fe, flag, true, user)),
        include(:kind => "summary")
      )
    end
  end

  it "ends debug mode based on client time if client time is later than server time" do
    with_processor_and_sender(default_config) do |ep, sender|
      # Pick a server time that is somewhat behind the client time
      server_time = Time.now - 20

      # Send and flush an event we don't care about, just to set the last server time
      sender.result = LaunchDarkly::Impl::EventSenderResult.new(true, false, server_time)
      ep.add_event({ kind: "identify", user: user })
      flush_and_get_events(ep, sender)

      # Now send an event with debug mode on, with a "debug until" time that is further in
      # the future than the server time, but in the past compared to the client.
      flag = { key: "flagkey", version: 11 }
      debug_until = (server_time.to_f * 1000).to_i + 1000
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: user,
        variation: 1, value: "value", trackEvents: false, debugEventsUntilDate: debug_until
      }
      ep.add_event(fe)

      # Should get a summary event only, not a full feature event
      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        include(:kind => "summary")
      )
    end
  end

  it "ends debug mode based on server time if server time is later than client time" do
    with_processor_and_sender(default_config) do |ep, sender|
      # Pick a server time that is somewhat ahead of the client time
      server_time = Time.now + 20

      # Send and flush an event we don't care about, just to set the last server time
      sender.result = LaunchDarkly::Impl::EventSenderResult.new(true, false, server_time)
      ep.add_event({ kind: "identify", user: user })
      flush_and_get_events(ep, sender)

      # Now send an event with debug mode on, with a "debug until" time that is further in
      # the future than the server time, but in the past compared to the client.
      flag = { key: "flagkey", version: 11 }
      debug_until = (server_time.to_f * 1000).to_i - 1000
      fe = {
        kind: "feature", key: "flagkey", version: 11, user: user,
        variation: 1, value: "value", trackEvents: false, debugEventsUntilDate: debug_until
      }
      ep.add_event(fe)

      # Should get a summary event only, not a full feature event
      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        include(:kind => "summary")
      )
    end
  end

  it "generates only one index event for multiple events with same user" do
    with_processor_and_sender(default_config) do |ep, sender|
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
      ep.add_event(fe1)
      ep.add_event(fe2)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(fe1, user)),
        eq(feature_event(fe1, flag1, false, nil)),
        eq(feature_event(fe2, flag2, false, nil)),
        include(:kind => "summary")
      )
    end
  end

  it "summarizes non-tracked events" do
    with_processor_and_sender(default_config) do |ep, sender|
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
      ep.add_event(fe1)
      ep.add_event(fe2)

      output = flush_and_get_events(ep, sender)
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
  end

  it "queues custom event with user" do
    with_processor_and_sender(default_config) do |ep, sender|
      e = { kind: "custom", key: "eventkey", user: user, data: { thing: "stuff" }, metricValue: 1.5 }
      ep.add_event(e)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(e, user)),
        eq(custom_event(e, nil))
      )
    end
  end

  it "can include inline user in custom event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(inline_users_in_events: true))
    with_processor_and_sender(config) do |ep, sender|
      e = { kind: "custom", key: "eventkey", user: user, data: { thing: "stuff" } }
      ep.add_event(e)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(custom_event(e, user))
      )
    end
  end

  it "filters user in custom event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(all_attributes_private: true, inline_users_in_events: true))
    with_processor_and_sender(config) do |ep, sender|
      e = { kind: "custom", key: "eventkey", user: user, data: { thing: "stuff" } }
      ep.add_event(e)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(custom_event(e, filtered_user))
      )
    end
  end

  it "stringifies built-in user attributes in custom event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(inline_users_in_events: true))
    with_processor_and_sender(config) do |ep, sender|
      e = { kind: "custom", key: "eventkey", user: numeric_user }
      ep.add_event(e)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(custom_event(e, stringified_numeric_user))
      )
    end
  end

  it "does a final flush when shutting down" do
    with_processor_and_sender(default_config) do |ep, sender|
      e = { kind: "identify", key: user[:key], user: user }
      ep.add_event(e)
      
      ep.stop

      output = sender.analytics_payloads.pop
      expect(output).to contain_exactly(e)
    end
  end

  it "sends nothing if there are no events" do
    with_processor_and_sender(default_config) do |ep, sender|
      ep.flush
      ep.wait_until_inactive
      expect(sender.analytics_payloads.empty?).to be true
    end
  end

  it "stops posting events after unrecoverable error" do
    with_processor_and_sender(default_config) do |ep, sender|
      sender.result = LaunchDarkly::Impl::EventSenderResult.new(false, true, nil)
      e = { kind: "identify", key: user[:key], user: user }
      ep.add_event(e)
      flush_and_get_events(ep, sender)

      e = { kind: "identify", key: user[:key], user: user }
      ep.add_event(e)
      ep.flush
      ep.wait_until_inactive
      expect(sender.analytics_payloads.empty?).to be true
    end
  end

  describe "diagnostic events" do
    let(:default_id) { LaunchDarkly::Impl::DiagnosticAccumulator.create_diagnostic_id('sdk_key') }
    let(:diagnostic_config) { LaunchDarkly::Config.new(diagnostic_opt_out: false, logger: $null_log) }

    def with_diagnostic_processor_and_sender(config)
      sender = FakeEventSender.new
      acc = LaunchDarkly::Impl::DiagnosticAccumulator.new(default_id)
      ep = subject.new("sdk_key", config, nil, acc,
        { diagnostic_recording_interval: 0.2, event_sender: sender })
      begin
        yield ep, sender
      ensure
        ep.stop
      end
    end

    it "sends init event" do
      with_diagnostic_processor_and_sender(diagnostic_config) do |ep, sender|
        event = sender.diagnostic_payloads.pop
        expect(event).to include({
          kind: 'diagnostic-init',
          id: default_id
        })
      end
    end

    it "sends periodic event" do
      with_diagnostic_processor_and_sender(diagnostic_config) do |ep, sender|
        init_event = sender.diagnostic_payloads.pop
        periodic_event = sender.diagnostic_payloads.pop
        expect(periodic_event).to include({
          kind: 'diagnostic',
          id: default_id,
          droppedEvents: 0,
          deduplicatedUsers: 0,
          eventsInLastBatch: 0,
          streamInits: []
        })
      end
    end

    it "counts events in queue from last flush and dropped events" do
      config = LaunchDarkly::Config.new(diagnostic_opt_out: false, capacity: 2, logger: $null_log)
      with_diagnostic_processor_and_sender(config) do |ep, sender|
        init_event = sender.diagnostic_payloads.pop

        ep.add_event({ kind: 'identify', user: user })
        ep.add_event({ kind: 'identify', user: user })
        ep.add_event({ kind: 'identify', user: user })
        flush_and_get_events(ep, sender)

        periodic_event = sender.diagnostic_payloads.pop
        expect(periodic_event).to include({
          kind: 'diagnostic',
          droppedEvents: 1,
          eventsInLastBatch: 2
        })
      end
    end

    it "counts deduplicated users" do
      with_diagnostic_processor_and_sender(diagnostic_config) do |ep, sender|
        init_event = sender.diagnostic_payloads.pop

        ep.add_event({ kind: 'custom', key: 'event1', user: user })
        ep.add_event({ kind: 'custom', key: 'event2', user: user })
        events = flush_and_get_events(ep, sender)

        periodic_event = sender.diagnostic_payloads.pop
        expect(periodic_event).to include({
          kind: 'diagnostic',
          deduplicatedUsers: 1
        })
      end
    end
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
    out[:metricValue] = e[:metricValue] if e.has_key?(:metricValue)
    out
  end

  def flush_and_get_events(ep, sender)
    ep.flush
    ep.wait_until_inactive
    sender.analytics_payloads.pop
  end

  class FakeEventSender
    attr_accessor :result
    attr_reader :analytics_payloads
    attr_reader :diagnostic_payloads

    def initialize
      @result = LaunchDarkly::Impl::EventSenderResult.new(true, false, nil)
      @analytics_payloads = Queue.new
      @diagnostic_payloads = Queue.new
    end

    def send_event_data(data, description, is_diagnostic)
      (is_diagnostic ? @diagnostic_payloads : @analytics_payloads).push(JSON.parse(data, symbolize_names: true))
      @result
    end
  end
end
