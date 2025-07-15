require "spec_helper"

require "ldclient-rb/impl/big_segments"
require "ldclient-rb/impl/evaluator"
require "ldclient-rb/interfaces"

def sdk_key
  "sdk-key"
end

def null_data
  LaunchDarkly::NullUpdateProcessor.new
end

def null_logger
  double.as_null_object
end

def base_config
  {
    data_source: null_data,
    send_events: false,
    logger: null_logger,
  }
end

def test_config(add_props = {})
  LaunchDarkly::Config.new(base_config.merge(add_props))
end

def with_client(config)
  ensure_close(LaunchDarkly::LDClient.new(sdk_key, config)) do |client|
    yield client
  end
end

def basic_context
  LaunchDarkly::LDContext::create({ "key": "user-key", kind: "user" })
end

module LaunchDarkly
  class CapturingFeatureStore
    attr_reader :received_data

    def init(all_data)
      @received_data = all_data
    end

    def stop
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
