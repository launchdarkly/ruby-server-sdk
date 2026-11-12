require "spec_helper"

require "ldclient-rb/impl/big_segments"
require "ldclient-rb/impl/evaluator"
require "ldclient-rb/data_system"
require "ldclient-rb/integrations/test_data"
require "ldclient-rb/interfaces"

def sdk_key
  "sdk-key"
end

def null_data_system
  LaunchDarkly::DataSystem.custom.build
end

def test_data_system(test_data)
  test_data_system_builder(test_data).build
end

def test_data_system_builder(test_data)
  LaunchDarkly::DataSystem.custom.synchronizers([test_data.test_data_ds_builder])
end

# A data system that polls the FDv2 endpoint of a test server.
def polling_data_system_builder(base_uri)
  LaunchDarkly::DataSystem.custom.synchronizers([LaunchDarkly::DataSystem.polling_ds_builder.base_uri(base_uri)])
end

# An FDv2 polling response body that transfers the given flags and segments in full.
def fdv2_poll_payload(flags: {}, segments: {})
  objects = flags.values.map { |f| { kind: "flag", item: f } } + segments.values.map { |s| { kind: "segment", item: s } }
  events = [
    { event: "server-intent", data: { payloads: [{ id: "test-payload", target: 1, intentCode: "xfer-full", reason: "payload-missing" }] } },
  ]
  objects.each do |o|
    events << { event: "put-object", data: { kind: o[:kind], key: o[:item][:key], version: o[:item][:version], object: o[:item] } }
  end
  events << { event: "payload-transferred", data: { state: "(p:test-payload:1)", version: 1 } }
  { events: events }.to_json
end

# A data system that never receives data. The client stays uninitialized.
def silent_data_system_builder
  LaunchDarkly::DataSystem.custom.synchronizers([LaunchDarkly::SilentSynchronizerBuilder.new])
end

def null_logger
  double.as_null_object
end

def base_config
  {
    data_system: null_data_system,
    send_events: false,
    logger: null_logger,
  }
end

def test_config(add_props = {})
  LaunchDarkly::Config.new(base_config.merge(add_props))
end

def with_client(config, wait_for_sec = 5)
  ensure_close(LaunchDarkly::LDClient.new(sdk_key, config, wait_for_sec)) do |client|
    yield client
  end
end

def basic_context
  LaunchDarkly::LDContext::create({ "key": "user-key", kind: "user" })
end

module LaunchDarkly
  class MockUpdateProcessor
    attr_reader :ready

    def initialize
      @ready = Concurrent::Event.new
      @started = false
      @stopped = false
    end

    def start
      @started = true
      @ready
    end

    def stop
      @stopped = true
    end

    def initialized?
      @ready.set?
    end

    def started?
      @started
    end

    def stopped?
      @stopped
    end
  end

  # A synchronizer that sends no data. Its sync method returns when the data system stops it.
  class SilentSynchronizer
    def initialize
      @stopped = Concurrent::Event.new
    end

    def name
      "silent"
    end

    def sync(_selector_store)
      @stopped.wait
    end

    def stop
      @stopped.set
    end
  end

  class SilentSynchronizerBuilder
    def build(_sdk_key, _config)
      SilentSynchronizer.new
    end
  end

  # A persistent store that keeps its data in a hash.
  class MockFeatureStore
    include Interfaces::FeatureStore

    def initialize
      @data = {}
      @initialized = false
    end

    def init(all_data)
      @data = all_data.transform_values(&:dup)
      @initialized = true
    end

    def get(kind, key)
      item = (@data[kind] || {})[key.to_sym]
      item.nil? || item[:deleted] ? nil : item
    end

    def all(kind)
      (@data[kind] || {}).reject { |_, item| item[:deleted] }
    end

    def upsert(kind, item)
      items = (@data[kind] ||= {})
      old = items[item[:key].to_sym]
      return false if !old.nil? && old[:version] >= item[:version]

      items[item[:key].to_sym] = item
      true
    end

    def delete(kind, key, version)
      upsert(kind, { key: key, version: version, deleted: true })
    end

    def initialized?
      @initialized
    end

    def stop
    end

    def monitoring_enabled?
      false
    end

    def available?
      true
    end
  end

  class CapturingFeatureStore < MockFeatureStore
    attr_reader :received_data

    def init(all_data)
      @received_data = all_data
      super
    end
  end

  class MockBigSegmentStore
    def initialize
      @metadata = nil
      @metadata_error = nil
      @memberships = {}
    end

    def get_metadata
      raise @metadata_error unless @metadata_error.nil?
      @metadata
    end

    def get_membership(context_hash)
      @memberships[context_hash]
    end

    def stop
    end

    def setup_metadata(last_up_to_date)
      @metadata = Interfaces::BigSegmentStoreMetadata.new(last_up_to_date.to_f * 1000)
    end

    def setup_metadata_error(ex)
      @metadata_error = ex
    end

    def setup_segment_for_context(user_key, segment, included)
      user_hash = Impl::BigSegmentStoreManager.hash_for_context_key(user_key)
      @memberships[user_hash] ||= {}
      @memberships[user_hash][Impl::Evaluator.make_big_segment_ref(segment)] = included
    end
  end

  class SimpleObserver
    def initialize(fn)
      @fn = fn
    end

    def update(value)
      @fn.call(value)
    end

    def self.adding_to_queue(q)
      new(->(value) { q << value })
    end
  end

  class MockHook
    include Interfaces::Hooks::Hook

    def initialize(before_evaluation, after_evaluation)
      @before_evaluation = before_evaluation
      @after_evaluation = after_evaluation
    end

    def metadata
      Interfaces::Hooks::Metadata.new("mock hook")
    end

    def before_evaluation(evaluation_series_context, data)
      @before_evaluation.call(evaluation_series_context, data)
    end

    def after_evaluation(evaluation_series_context, data, detail)
      @after_evaluation.call(evaluation_series_context, data, detail)
    end
  end

  class MockPlugin
    include Interfaces::Plugins::Plugin

    def initialize(name, hooks = [], register_callback = nil)
      @name = name
      @hooks = hooks
      @register_callback = register_callback
    end

    def metadata
      Interfaces::Plugins::PluginMetadata.new(@name)
    end

    def get_hooks(environment_metadata)
      @hooks
    end

    def register(client, environment_metadata)
      @register_callback.call(client, environment_metadata) if @register_callback
    end
  end
end
