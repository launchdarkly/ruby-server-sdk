require "feature_store_spec_base"
require "diplomat"
require "spec_helper"

# These tests will all fail if there isn't a local Consul instance running.
# They can be disabled with LD_SKIP_DATABASE_TESTS=1

$consul_base_opts = {
  prefix: $my_prefix,
  logger: $null_log
}

class ConsulStoreTester
  def initialize(options)
    @options = options
    @actual_prefix = @options[:prefix] || LaunchDarkly::Integrations::Consul.default_prefix
  end

  def clear_data
    Diplomat::Kv.delete(@actual_prefix + '/', recurse: true)
  end

  def create_feature_store
    LaunchDarkly::Integrations::Consul.new_feature_store(@options)
  end
end


describe "Consul feature store" do
  break if ENV['LD_SKIP_DATABASE_TESTS'] == '1'
  
  include_examples "persistent_feature_store", ConsulStoreTester
end

# There isn't a Big Segments integration for Consul.
