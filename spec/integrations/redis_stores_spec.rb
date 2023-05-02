require "ldclient-rb/impl/integrations/redis_impl"

require "big_segment_store_spec_base"
require "feature_store_spec_base"
require "spec_helper"

require "redis"

# These tests will all fail if there isn't a local Redis instance running.
# They can be enabled with LD_SKIP_DATABASE_TESTS=0

$RedisBigSegmentStore = LaunchDarkly::Impl::Integrations::Redis::RedisBigSegmentStore

def with_redis_test_client
  ensure_close(Redis.new({ url: "redis://localhost:6379" })) do |client|
    yield client
  end
end


class RedisStoreTester
  def initialize(options)
    @options = options
    @actual_prefix = @options[:prefix] ||LaunchDarkly::Integrations::Redis.default_prefix
  end

  def clear_data
    with_redis_test_client do |client|
      keys = client.keys("#{@actual_prefix}:*")
      keys.each { |key| client.del(key) }
    end
  end

  def create_feature_store
    LaunchDarkly::Integrations::Redis::new_feature_store(@options)
  end

  def create_big_segment_store
    LaunchDarkly::Integrations::Redis.new_big_segment_store(@options)
  end

  def set_big_segments_metadata(metadata)
    with_redis_test_client do |client|
      client.set(@actual_prefix + $RedisBigSegmentStore::KEY_LAST_UP_TO_DATE,
        metadata.last_up_to_date.nil? ? "" : metadata.last_up_to_date.to_s)
    end
  end

  def set_big_segments(context_hash, includes, excludes)
    with_redis_test_client do |client|
      includes.each do |ref|
        client.sadd?(@actual_prefix + $RedisBigSegmentStore::KEY_CONTEXT_INCLUDE + context_hash, ref)
      end
      excludes.each do |ref|
        client.sadd?(@actual_prefix + $RedisBigSegmentStore::KEY_CONTEXT_EXCLUDE + context_hash, ref)
      end
    end
  end
end


describe "Redis feature store" do
  break unless ENV['LD_SKIP_DATABASE_TESTS'] == '0'

  include_examples "persistent_feature_store", RedisStoreTester

  def make_concurrent_modifier_test_hook(other_client, flag, start_version, end_version)
    test_hook = Object.new
    version_counter = start_version
    expect(test_hook).to receive(:before_update_transaction) { |base_key, key|
      if version_counter <= end_version
        new_flag = flag.clone
        new_flag[:version] = version_counter
        other_client.hset(base_key, key, new_flag.to_json)
        version_counter = version_counter + 1
      end
    }.at_least(:once)
    test_hook
  end

  tester = RedisStoreTester.new({ logger: $null_logger })

  it "should have monitoring enabled and defaults to available" do
    tester = RedisStoreTester.new({ logger: $null_logger })

    ensure_stop(tester.create_feature_store) do |store|
      expect(store.monitoring_enabled?).to be true
      expect(store.available?).to be true
    end
  end

  it "can detect that a non-existent store is not available" do
    # Short timeout so we don't delay the tests too long
    tester = RedisStoreTester.new({ redis_opts: { url: "redis://i-mean-what-are-the-odds:13579", timeout: 0.1 }, logger: $null_logger })

    ensure_stop(tester.create_feature_store) do |store|
      expect(store.available?).to be false
    end
  end

  it "handles upsert race condition against external client with lower version" do
    with_redis_test_client do |other_client|
      flag = { key: "foo", version: 1 }
      test_hook = make_concurrent_modifier_test_hook(other_client, flag, 2, 4)
      tester = RedisStoreTester.new({ test_hook: test_hook, logger: $null_logger })

      ensure_stop(tester.create_feature_store) do |store|
        store.init(LaunchDarkly::FEATURES => { flag[:key] => flag })

        my_ver = { key: "foo", version: 10 }
        store.upsert(LaunchDarkly::FEATURES, my_ver)
        result = store.get(LaunchDarkly::FEATURES, flag[:key])
        expect(result[:version]).to eq 10
      end
    end
  end

  it "handles upsert race condition against external client with higher version" do
    with_redis_test_client do |other_client|
      flag = { key: "foo", version: 1 }
      test_hook = make_concurrent_modifier_test_hook(other_client, flag, 3, 3)
      tester = RedisStoreTester.new({ test_hook: test_hook, logger: $null_logger })

      ensure_stop(tester.create_feature_store) do |store|
        store.init(LaunchDarkly::FEATURES => { flag[:key] => flag })

        my_ver = { key: "foo", version: 2 }
        store.upsert(LaunchDarkly::FEATURES, my_ver)
        result = store.get(LaunchDarkly::FEATURES, flag[:key])
        expect(result[:version]).to eq 3
      end
    end
  end

  it "shuts down a custom Redis pool by default" do
    unowned_pool = ConnectionPool.new(size: 1, timeout: 1) { Redis.new({ url: "redis://localhost:6379" }) }
    tester = RedisStoreTester.new({ pool: unowned_pool, logger: $null_logger })
    store = tester.create_feature_store

    begin
      store.init(LaunchDarkly::FEATURES => { })
      store.stop

      expect { unowned_pool.with {} }.to raise_error(ConnectionPool::PoolShuttingDownError)
    ensure
      unowned_pool.shutdown { |conn| conn.close }
    end
  end

  it "doesn't shut down a custom Redis pool if pool_shutdown_on_close = false" do
    unowned_pool = ConnectionPool.new(size: 1, timeout: 1) { Redis.new({ url: "redis://localhost:6379" }) }
    tester = RedisStoreTester.new({ pool: unowned_pool, pool_shutdown_on_close: false, logger: $null_logger })
    store = tester.create_feature_store

    begin
      store.init(LaunchDarkly::FEATURES => { })
      store.stop

      expect { unowned_pool.with {} }.not_to raise_error
    ensure
      unowned_pool.shutdown { |conn| conn.close }
    end
  end
end

describe "Redis big segment store" do
  break unless ENV['LD_SKIP_DATABASE_TESTS'] == '0'

  include_examples "big_segment_store", RedisStoreTester
end
