require "feature_store_spec_base"
#require "diplomat"
require "spec_helper"


$my_prefix = 'testprefix'
$null_log = ::Logger.new($stdout)
$null_log.level = ::Logger::FATAL

$base_opts = {
  prefix: $my_prefix,
  logger: $null_log
}

def create_consul_store(opts = {})
  LaunchDarkly::Integrations::Consul::new_feature_store(
    opts.merge($base_opts).merge({ expiration: 60 }))
end

def create_consul_store_uncached(opts = {})
  LaunchDarkly::Integrations::Consul::new_feature_store(
    opts.merge($base_opts).merge({ expiration: 0 }))
end


describe "Consul feature store" do
  
  # These tests will all fail if there isn't a local Consul instance running.
  
  context "with local cache" do
    include_examples "feature_store", method(:create_consul_store)
  end

  context "without local cache" do
    include_examples "feature_store", method(:create_consul_store_uncached)
  end
end
