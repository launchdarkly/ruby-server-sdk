require "feature_store_spec_base"
require "diplomat"
require "spec_helper"

# These tests will all fail if there isn't a local Consul instance running.
# They can be enabled with LD_SKIP_DATABASE_TESTS=0

$consul_base_opts = {
  prefix: $my_prefix,
  logger: $null_log,
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
  break unless ENV['LD_SKIP_DATABASE_TESTS'] == '0'

  before do
    Diplomat.configuration = Diplomat::Configuration.new
  end

  include_examples "persistent_feature_store", ConsulStoreTester

  it "should have monitoring enabled and defaults to available" do
    tester = ConsulStoreTester.new({ logger: $null_logger })

    ensure_stop(tester.create_feature_store) do |store|
      expect(store.monitoring_enabled?).to be true
      expect(store.available?).to be true
    end
  end

  it "can detect that a non-existent store is not available" do
    Diplomat.configure do |config|
      config.url = 'http://i-mean-what-are-the-odds:13579'
      config.options[:request] ||= {}
      # Short timeout so we don't delay the tests too long
      config.options[:request][:timeout] = 0.1
    end
    tester = ConsulStoreTester.new({ consul_config: Diplomat.configuration })

    ensure_stop(tester.create_feature_store) do |store|
      expect(store.available?).to be false
    end
  end

end

# There isn't a Big Segments integration for Consul.
