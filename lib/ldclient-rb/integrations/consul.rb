require "ldclient-rb/impl/integrations/consul_impl"
require "ldclient-rb/integrations/util/store_wrapper"

module LaunchDarkly
  module Integrations
    module Consul
      #
      # Default value for the `prefix` option for {new_feature_store}.
      #
      # @return [String]  the default key prefix
      #
      def self.default_prefix
        'launchdarkly'
      end

      #
      # Creates a Consul-backed persistent feature store.
      #
      # To use this method, you must first install the gem `diplomat`. Then, put the object returned by
      # this method into the `feature_store` property of your client configuration ({LaunchDarkly::Config}).
      #
      # @param opts [Hash] the configuration options
      # @option opts [Hash] :consul_config  an instance of `Diplomat::Configuration` to replace the default
      #   Consul client configuration
      # @option opts [String] :prefix  namespace prefix to add to all keys used by LaunchDarkly
      # @option opts [Logger] :logger  a `Logger` instance; defaults to `Config.default_logger`
      # @option opts [Integer] :expiration_seconds (15)  expiration time for the in-memory cache, in seconds; 0 for no local caching
      # @option opts [Integer] :capacity (1000)  maximum number of items in the cache
      # @return [LaunchDarkly::Interfaces::FeatureStore]  a feature store object
      #
      def self.new_feature_store(opts, &block)
        core = LaunchDarkly::Impl::Integrations::Consul::ConsulFeatureStoreCore.new(opts)
        return LaunchDarkly::Integrations::Util::CachingStoreWrapper.new(core, opts)
      end
    end
  end
end
