require "ldclient-rb/redis_store"  # eventually we will just refer to impl/integrations/redis_impl directly

module LaunchDarkly
  module Integrations
    module Redis
      #
      # Default value for the `redis_url` option for {new_feature_store}. This points to an instance of
      # Redis running at `localhost` with its default port.
      #
      # @return [String]  the default Redis URL
      #
      def self.default_redis_url
        'redis://localhost:6379/0'
      end

      #
      # Default value for the `prefix` option for {new_feature_store}.
      #
      # @return [String]  the default key prefix
      #
      def self.default_prefix
        'launchdarkly'
      end

      #
      # Creates a Redis-backed persistent feature store.
      #
      # To use this method, you must first have the `redis` and `connection-pool` gems installed. Then,
      # put the object returned by this method into the `feature_store` property of your
      # client configuration ({LaunchDarkly::Config}).
      #
      # @param opts [Hash] the configuration options
      # @option opts [String] :redis_url (default_redis_url)  URL of the Redis instance (shortcut for omitting `redis_opts`)
      # @option opts [Hash] :redis_opts  options to pass to the Redis constructor (if you want to specify more than just `redis_url`)
      # @option opts [String] :prefix (default_prefix)  namespace prefix to add to all hash keys used by LaunchDarkly
      # @option opts [Logger] :logger  a `Logger` instance; defaults to `Config.default_logger`
      # @option opts [Integer] :max_connections  size of the Redis connection pool
      # @option opts [Integer] :expiration_seconds (15)  expiration time for the in-memory cache, in seconds; 0 for no local caching
      # @option opts [Integer] :capacity (1000)  maximum number of items in the cache
      # @option opts [Object] :pool  custom connection pool, if desired
      # @return [LaunchDarkly::Interfaces::FeatureStore]  a feature store object
      #
      def self.new_feature_store(opts)
        return RedisFeatureStore.new(opts)
      end
    end
  end
end
