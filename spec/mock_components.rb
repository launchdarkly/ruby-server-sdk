require "spec_helper"

require "ldclient-rb/impl/big_segments"
require "ldclient-rb/impl/evaluator"
require "ldclient-rb/impl/data_source/null_processor"
require "ldclient-rb/interfaces"

def sdk_key
  "sdk-key"
end

def null_data
  LaunchDarkly::Impl::DataSource::NullUpdateProcessor.new
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

  #
  # A Big Segment store whose metadata queries wait for the test to supply each result.
  #
  # The status poller notifies observers of one result before it starts its next query. Once a
  # test sees a query start, every earlier result has been delivered, and the poller stays in that
  # query until the test supplies another result.
  #
  # Call {#release} before closing the client. The poller cannot stop while a query is waiting.
  #
  class GatedBigSegmentStore
    def initialize
      @lock = Mutex.new
      @changed = ConditionVariable.new
      @results = []
      @last_result = nil
      @queries_started = 0
      @released = false
    end

    def get_metadata
      result = @lock.synchronize do
        @queries_started += 1
        @changed.broadcast
        @changed.wait(@lock) while @results.empty? && !@released
        @last_result = @results.shift unless @results.empty?
        @last_result
      end
      raise result if result.is_a?(Exception)
      result
    end

    def get_membership(_context_hash)
      nil
    end

    def stop
    end

    # Supplies the result of the next metadata query.
    def queue_metadata(last_up_to_date)
      queue_result(Interfaces::BigSegmentStoreMetadata.new(last_up_to_date.to_f * 1000))
    end

    # Makes the next metadata query raise the given error.
    def queue_metadata_error(ex)
      queue_result(ex)
    end

    #
    # Blocks until the store has received `count` metadata queries, or until the timeout passes.
    #
    # @return [Boolean] false if the queries did not start within the timeout
    #
    def wait_for_queries(count, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @lock.synchronize do
        while @queries_started < count
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if remaining <= 0
          @changed.wait(@lock, remaining)
        end
        true
      end
    end

    # Stops queries from waiting. Waiting and later queries return the last result again.
    def release
      @lock.synchronize do
        @released = true
        @changed.broadcast
      end
    end

    private def queue_result(result)
      @lock.synchronize do
        @results << result
        @changed.broadcast
      end
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
