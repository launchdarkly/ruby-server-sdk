require "segment_store_spec_base"
require "json"
require "spec_helper"



$my_prefix = 'testprefix'
$null_log = ::Logger.new($stdout)
$null_log.level = ::Logger::FATAL


def create_redis_store()
  LaunchDarkly::RedisSegmentStore.new(prefix: $my_prefix, logger: $null_log, expiration: 60)
end

def create_redis_store_uncached()
  LaunchDarkly::RedisSegmentStore.new(prefix: $my_prefix, logger: $null_log, expiration: 0)
end


describe LaunchDarkly::RedisSegmentStore do
  subject { LaunchDarkly::RedisSegmentStore }
  
  let(:segment0_with_higher_version) do
    f = segment0.clone
    f[:version] = segment0[:version] + 10
    f
  end

  # These tests will all fail if there isn't a Redis instance running on the default port.
  
  context "real Redis with local cache" do

    include_examples "segment_store", method(:create_redis_store)

  end

  context "real Redis without local cache" do

    include_examples "segment_store", method(:create_redis_store_uncached)

  end
end
