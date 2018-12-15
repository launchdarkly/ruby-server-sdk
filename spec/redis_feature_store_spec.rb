require "feature_store_spec_base"
require "json"
require "redis"
require "spec_helper"



$my_prefix = 'testprefix'
$null_log = ::Logger.new($stdout)
$null_log.level = ::Logger::FATAL


def create_redis_store(opts = {})
  LaunchDarkly::RedisFeatureStore.new(opts.merge({ prefix: $my_prefix, logger: $null_log, expiration: 60 }))
end

def create_redis_store_uncached(opts = {})
  LaunchDarkly::RedisFeatureStore.new(opts.merge({ prefix: $my_prefix, logger: $null_log, expiration: 0 }))
end


describe LaunchDarkly::RedisFeatureStore do
  subject { LaunchDarkly::RedisFeatureStore }
  
  # These tests will all fail if there isn't a Redis instance running on the default port.
  
  context "real Redis with local cache" do
    include_examples "feature_store", method(:create_redis_store)
  end

  context "real Redis without local cache" do
    include_examples "feature_store", method(:create_redis_store_uncached)
  end

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

  it "handles upsert race condition against external client with lower version" do
    other_client = Redis.new({ url: "redis://localhost:6379" })
    flag = { key: "foo", version: 1 }
    test_hook = make_concurrent_modifier_test_hook(other_client, flag, 2, 4)
    store = create_redis_store({ test_hook: test_hook })
    
    begin
      store.init(LaunchDarkly::FEATURES => { flag[:key] => flag })

      my_ver = { key: "foo", version: 10 }
      store.upsert(LaunchDarkly::FEATURES, my_ver)
      result = store.get(LaunchDarkly::FEATURES, flag[:key])
      expect(result[:version]).to eq 10
    ensure
      other_client.close
    end
  end

  it "handles upsert race condition against external client with higher version" do
    other_client = Redis.new({ url: "redis://localhost:6379" })
    flag = { key: "foo", version: 1 }
    test_hook = make_concurrent_modifier_test_hook(other_client, flag, 3, 3)
    store = create_redis_store({ test_hook: test_hook })
    
    begin
      store.init(LaunchDarkly::FEATURES => { flag[:key] => flag })

      my_ver = { key: "foo", version: 2 }
      store.upsert(LaunchDarkly::FEATURES, my_ver)
      result = store.get(LaunchDarkly::FEATURES, flag[:key])
      expect(result[:version]).to eq 3
    ensure
      other_client.close
    end
  end
end
