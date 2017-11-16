require "feature_store_spec_base"
require "json"
require "spec_helper"



$my_prefix = 'testprefix'
$null_log = ::Logger.new($stdout)
$null_log.level = ::Logger::FATAL


def create_redis_store()
  LaunchDarkly::RedisFeatureStore.new(prefix: $my_prefix, logger: $null_log, expiration: 60)
end

def create_redis_store_uncached()
  LaunchDarkly::RedisFeatureStore.new(prefix: $my_prefix, logger: $null_log, expiration: 0)
end


describe LaunchDarkly::RedisFeatureStore do
  subject { LaunchDarkly::RedisFeatureStore }
  
  let(:feature0_with_higher_version) do
    f = feature0.clone
    f[:version] = feature0[:version] + 10
    f
  end

  # These tests will all fail if there isn't a Redis instance running on the default port.
  
  context "real Redis with local cache" do

    include_examples "feature_store", method(:create_redis_store)

  end

  context "real Redis without local cache" do

    include_examples "feature_store", method(:create_redis_store_uncached)

  end
end
