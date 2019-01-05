require "ldclient-rb/interfaces"
require "ldclient-rb/impl/integrations/redis_impl"

module LaunchDarkly
  #
  # An implementation of the LaunchDarkly client's feature store that uses a Redis
  # instance.  This object holds feature flags and related data received from the
  # streaming API.  Feature data can also be further cached in memory to reduce overhead
  # of calls to Redis.
  #
  # To use this class, you must first have the `redis` and `connection-pool` gems
  # installed.  Then, create an instance and store it in the `feature_store` property
  # of your client configuration.
  #
  # @deprecated Use the factory method in {LaunchDarkly::Integrations::Redis} instead. This specific
  #   implementation class may change in the future.
  #
  class RedisFeatureStore
    include LaunchDarkly::Interfaces::FeatureStore

    # Note that this class is now just a facade around CachingStoreWrapper, which is in turn delegating
    # to RedisFeatureStoreCore where the actual database logic is. This class was retained for historical
    # reasons, so that existing code can still call RedisFeatureStore.new. In the future, we will migrate
    # away from exposing these concrete classes and use factory methods instead.

    #
    # Constructor for a RedisFeatureStore instance.
    #
    # @param opts [Hash] the configuration options
    # @option opts [String] :redis_url  URL of the Redis instance (shortcut for omitting redis_opts)
    # @option opts [Hash] :redis_opts  options to pass to the Redis constructor (if you want to specify more than just redis_url)
    # @option opts [String] :prefix  namespace prefix to add to all hash keys used by LaunchDarkly
    # @option opts [Logger] :logger  a `Logger` instance; defaults to `Config.default_logger`
    # @option opts [Integer] :max_connections  size of the Redis connection pool
    # @option opts [Integer] :expiration_seconds  expiration time for the in-memory cache, in seconds; 0 for no local caching
    # @option opts [Integer] :capacity  maximum number of feature flags (or related objects) to cache locally
    # @option opts [Object] :pool  custom connection pool, if desired
    #
    def initialize(opts = {})
      core = LaunchDarkly::Impl::Integrations::Redis::RedisFeatureStoreCore.new(opts)
      @wrapper = LaunchDarkly::Integrations::Util::CachingStoreWrapper.new(core, opts)
    end

    #
    # Default value for the `redis_url` constructor parameter; points to an instance of Redis
    # running at `localhost` with its default port.
    #
    def self.default_redis_url
      LaunchDarkly::Integrations::Redis::default_redis_url
    end

    #
    # Default value for the `prefix` constructor parameter.
    #
    def self.default_prefix
      LaunchDarkly::Integrations::Redis::default_prefix
    end

    def get(kind, key)
      @wrapper.get(kind, key)
    end

    def all(kind)
      @wrapper.all(kind)
    end

    def delete(kind, key, version)
      @wrapper.delete(kind, key, version)
    end

    def init(all_data)
      @wrapper.init(all_data)
    end

    def upsert(kind, item)
      @wrapper.upsert(kind, item)
    end

    def initialized?
      @wrapper.initialized?
    end

    def stop
      @wrapper.stop
    end
  end
end
