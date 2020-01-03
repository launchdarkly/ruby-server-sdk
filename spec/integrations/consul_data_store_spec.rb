require "data_store_spec_base"
require "diplomat"
require "spec_helper"


$my_prefix = 'testprefix'
$null_log = ::Logger.new($stdout)
$null_log.level = ::Logger::FATAL

$consul_base_opts = {
  prefix: $my_prefix,
  logger: $null_log
}

def create_consul_store(opts = {})
  LaunchDarkly::Integrations::Consul::new_data_store(
    $consul_base_opts.merge(opts).merge({ expiration: 60 }))
end

def create_consul_store_uncached(opts = {})
  LaunchDarkly::Integrations::Consul::new_data_store(
    $consul_base_opts.merge(opts).merge({ expiration: 0 }))
end

def clear_all_data
  Diplomat::Kv.delete($my_prefix + '/', recurse: true)
end


describe "Consul data store" do
  break if ENV['LD_SKIP_DATABASE_TESTS'] == '1'
  
  # These tests will all fail if there isn't a local Consul instance running.
  
  context "with local cache" do
    include_examples "data_store", method(:create_consul_store), method(:clear_all_data)
  end

  context "without local cache" do
    include_examples "data_store", method(:create_consul_store_uncached), method(:clear_all_data)
  end
end
