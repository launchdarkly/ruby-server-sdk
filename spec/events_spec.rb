require "ldclient-rb/impl/event_types"

require "events_test_util"
require "http_util"
require "spec_helper"
require "time"

describe LaunchDarkly::EventProcessor do
  subject { LaunchDarkly::EventProcessor }

  let(:starting_timestamp) { 1000 }
  let(:default_config_opts) { { diagnostic_opt_out: true, logger: $null_log } }
  let(:default_config) { LaunchDarkly::Config.new(default_config_opts) }
  let(:context) { LaunchDarkly::LDContext.create({ kind: "user", key: "userkey", name: "Red" }) }

  def with_processor_and_sender(config)
    sender = FakeEventSender.new
    timestamp = starting_timestamp
    ep = subject.new("sdk_key", config, nil, nil, {
      event_sender: sender,
      timestamp_fn: proc {
        t = timestamp
        timestamp += 1
        t
      },
    })
    begin
      yield ep, sender
    ensure
      ep.stop
    end
  end

  it "queues identify event" do
    with_processor_and_sender(default_config) do |ep, sender|
      ep.record_identify_event(context)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(eq(identify_event(default_config, context)))
    end
  end

  it "filters context in identify event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(all_attributes_private: true))
    with_processor_and_sender(config) do |ep, sender|
      ep.record_identify_event(context)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(eq(identify_event(config, context)))
    end
  end

  it "queues individual feature event with index event" do
    with_processor_and_sender(default_config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      ep.record_eval_event(context, 'flagkey', 11, 1, 'value', nil, nil, true)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(default_config, context)),
        eq(feature_event(flag, context, 1, 'value')),
        include(:kind => "summary")
      )
    end
  end

  it "filters context in index event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(all_attributes_private: true))
    with_processor_and_sender(config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      ep.record_eval_event(context, 'flagkey', 11, 1, 'value', nil, nil, true)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(config, context)),
        eq(feature_event(flag, context, 1, 'value')),
        include(:kind => "summary")
      )
    end
  end

  it "filters context in feature event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(all_attributes_private: true))
    with_processor_and_sender(config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      ep.record_eval_event(context, 'flagkey', 11, 1, 'value', nil, nil, true)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(config, context)),
        eq(feature_event(flag, context, 1, 'value')),
        include(:kind => "summary")
      )
    end
  end

  it "sets event kind to debug if flag is temporarily in debug mode" do
    with_processor_and_sender(default_config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      future_time = (Time.now.to_f * 1000).to_i + 1000000
      ep.record_eval_event(context, 'flagkey', 11, 1, 'value', nil, nil, false, future_time)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(default_config, context)),
        eq(debug_event(default_config, flag, context, 1, 'value')),
        include(:kind => "summary")
      )
    end
  end

  it "can be both debugging and tracking an event" do
    with_processor_and_sender(default_config) do |ep, sender|
      flag = { key: "flagkey", version: 11 }
      future_time = (Time.now.to_f * 1000).to_i + 1000000
      ep.record_eval_event(context, 'flagkey', 11, 1, 'value', nil, nil, true, future_time)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(default_config, context)),
        eq(feature_event(flag, context, 1, 'value')),
        eq(debug_event(default_config, flag, context, 1, 'value')),
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

      ep.record_identify_event(context)
      flush_and_get_events(ep, sender)

      # Now send an event with debug mode on, with a "debug until" time that is further in
      # the future than the server time, but in the past compared to the client.
      flag = { key: "flagkey", version: 11 }
      debug_until = (server_time.to_f * 1000).to_i + 1000
      ep.record_eval_event(context, 'flagkey', 11, 1, 'value', nil, nil, false, debug_until)

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
      ep.record_identify_event(context)
      flush_and_get_events(ep, sender)

      # Now send an event with debug mode on, with a "debug until" time that is further in
      # the future than the server time, but in the past compared to the client.
      flag = { key: "flagkey", version: 11 }
      debug_until = (server_time.to_f * 1000).to_i - 1000
      ep.record_eval_event(context, 'flagkey', 11, 1, 'value', nil, nil, false, debug_until)

      # Should get a summary event only, not a full feature event
      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        include(:kind => "summary")
      )
    end
  end

  it "generates only one index event for multiple events with same context" do
    with_processor_and_sender(default_config) do |ep, sender|
      flag1 = { key: "flagkey1", version: 11 }
      flag2 = { key: "flagkey2", version: 22 }
      future_time = (Time.now.to_f * 1000).to_i + 1000000
      ep.record_eval_event(context, 'flagkey1', 11, 1, 'value', nil, nil, true)
      ep.record_eval_event(context, 'flagkey2', 22, 1, 'value', nil, nil, true)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(default_config, context)),
        eq(feature_event(flag1, context, 1, 'value', starting_timestamp)),
        eq(feature_event(flag2, context, 1, 'value', starting_timestamp + 1)),
        include(:kind => "summary")
      )
    end
  end

  it "summarizes non-tracked events" do
    with_processor_and_sender(default_config) do |ep, sender|
      ep.record_eval_event(context, 'flagkey1', 11, 1, 'value1', nil, 'default1', false)
      ep.record_eval_event(context, 'flagkey2', 22, 2, 'value2', nil, 'default2', false)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(default_config, context)),
        eq({
          kind: "summary",
          startDate: starting_timestamp,
          endDate: starting_timestamp + 1,
          features: {
            flagkey1: {
              contextKinds: ["user"],
              default: "default1",
              counters: [
                { version: 11, variation: 1, value: "value1", count: 1 },
              ],
            },
            flagkey2: {
              contextKinds: ["user"],
              default: "default2",
              counters: [
                { version: 22, variation: 2, value: "value2", count: 1 },
              ],
            },
          },
        })
      )
    end
  end

  it "queues custom event with context" do
    with_processor_and_sender(default_config) do |ep, sender|
      ep.record_custom_event(context, 'eventkey', { thing: 'stuff' }, 1.5)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(default_config, context)),
        eq(custom_event(context, 'eventkey', { thing: 'stuff' }, 1.5))
      )
    end
  end

  it "filters context in custom event" do
    config = LaunchDarkly::Config.new(default_config_opts.merge(all_attributes_private: true))
    with_processor_and_sender(config) do |ep, sender|
      ep.record_custom_event(context, 'eventkey')

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(
        eq(index_event(config, context)),
        eq(custom_event(context, 'eventkey', nil, nil))
      )
    end
  end

  it "treats nil value for custom the same as an empty hash" do
    with_processor_and_sender(default_config) do |ep, sender|
      user_with_nil_custom = LaunchDarkly::LDContext.create({ key: "userkey", custom: nil })
      ep.record_identify_event(user_with_nil_custom)

      output = flush_and_get_events(ep, sender)
      expect(output).to contain_exactly(eq(identify_event(default_config, user_with_nil_custom)))
    end
  end

  it "does a final flush when shutting down" do
    with_processor_and_sender(default_config) do |ep, sender|
      ep.record_identify_event(context)

      ep.stop

      output = sender.analytics_payloads.pop
      expect(output).to contain_exactly(eq(identify_event(default_config, context)))
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
      e = ep.record_identify_event(context)
      flush_and_get_events(ep, sender)

      ep.record_identify_event(context)
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
          id: default_id,
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
          streamInits: [],
        })
      end
    end

    it "counts events in queue from last flush and dropped events" do
      config = LaunchDarkly::Config.new(diagnostic_opt_out: false, capacity: 2, logger: $null_log)
      with_diagnostic_processor_and_sender(config) do |ep, sender|
        init_event = sender.diagnostic_payloads.pop

        3.times do
          ep.record_identify_event(context)
        end
        flush_and_get_events(ep, sender)

        periodic_event = sender.diagnostic_payloads.pop
        expect(periodic_event).to include({
          kind: 'diagnostic',
          droppedEvents: 1,
          eventsInLastBatch: 2,
        })
      end
    end

    it "counts deduplicated contexts" do
      with_diagnostic_processor_and_sender(diagnostic_config) do |ep, sender|
        sender.diagnostic_payloads.pop

        ep.record_custom_event(context, 'event1')
        ep.record_custom_event(context, 'event2')
        flush_and_get_events(ep, sender)

        periodic_event = sender.diagnostic_payloads.pop
        expect(periodic_event).to include({
          kind: 'diagnostic',
          deduplicatedUsers: 1,
        })
      end
    end
  end

  #
  # @param config [LaunchDarkly::Config]
  # @param context [LaunchDarkly::LDContext]
  # @param timestamp [Integer]
  # @return [Hash]
  #
  def index_event(config, context, timestamp = starting_timestamp)
    context_filter = LaunchDarkly::Impl::ContextFilter.new(config.all_attributes_private, config.private_attributes)
    out = {
      kind: "index",
      creationDate: timestamp,
      context: context_filter.filter(context),
    }
    JSON.parse(out.to_json, symbolize_names: true)
  end

  #
  # @param config [LaunchDarkly::Config]
  # @param context [LaunchDarkly::LDContext]
  # @param timestamp [Integer]
  # @return [Hash]
  #
  def identify_event(config, context, timestamp = starting_timestamp)
    context_filter = LaunchDarkly::Impl::ContextFilter.new(config.all_attributes_private, config.private_attributes)
    out = {
      kind: "identify",
      creationDate: timestamp,
      key: context.fully_qualified_key,
      context: context_filter.filter(context),
    }
    JSON.parse(out.to_json, symbolize_names: true)
  end

  #
  # @param flag [Hash]
  # @param context [LaunchDarkly::LDContext]
  # @param variation [Integer]
  # @param value [any]
  # @param timestamp [Integer]
  # @return [Hash]
  #
  def feature_event(flag, context, variation, value, timestamp = starting_timestamp)
    out = {
      kind: 'feature',
      creationDate: timestamp,
      contextKeys: context.keys,
      key: flag[:key],
      variation: variation,
      version: flag[:version],
      value: value,
    }
    JSON.parse(out.to_json, symbolize_names: true)
  end

  #
  # @param config [LaunchDarkly::Config]
  # @param flag [Hash]
  # @param context [LaunchDarkly::LDContext]
  # @param variation [Integer]
  # @param value [any]
  # @param timestamp [Integer]
  # @return [Hash]
  #
  def debug_event(config, flag, context, variation, value, timestamp = starting_timestamp)
    context_filter = LaunchDarkly::Impl::ContextFilter.new(config.all_attributes_private, config.private_attributes)
    out = {
      kind: 'debug',
      creationDate: timestamp,
      key: flag[:key],
      variation: variation,
      version: flag[:version],
      value: value,
      context: context_filter.filter(context),
    }
    JSON.parse(out.to_json, symbolize_names: true)
  end

  #
  # @param context [LaunchDarkly::LDContext]
  # @param key [String]
  # @param data [any]
  # @param metric_value [any]
  # @return [Hash]
  #
  def custom_event(context, key, data, metric_value)
    out = {
      kind: "custom",
      creationDate: starting_timestamp,
      contextKeys: context.keys,
      key: key,
    }
    out[:data] = data unless data.nil?
    out[:metricValue] = metric_value unless metric_value.nil?

    JSON.parse(out.to_json, symbolize_names: true)
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
