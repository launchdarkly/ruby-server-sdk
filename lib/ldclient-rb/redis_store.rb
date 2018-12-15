require "concurrent/atomics"
require "json"

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
  # @deprecated Use {LaunchDarkly::Integrations::Redis#new_feature_store} instead. This specific
  #   implementation class may change in the future.
  #
  class RedisFeatureStore
    begin
      require "redis"
      require "connection_pool"
      REDIS_ENABLED = true
    rescue ScriptError, StandardError
      REDIS_ENABLED = false
    end

    include LaunchDarkly::Interfaces::FeatureStore

    #
    # Internal implementation of the Redis feature store. We put a CachingStoreWrapper around this.
    #
    class RedisFeatureStoreCore
      def initialize(opts)
        @redis_opts = opts[:redis_opts] || Hash.new
        if opts[:redis_url]
          @redis_opts[:url] = opts[:redis_url]
        end
        if !@redis_opts.include?(:url)
          @redis_opts[:url] = LaunchDarkly::Integrations::Redis::default_redis_url
        end
        max_connections = opts[:max_connections] || 16
        @pool = opts[:pool] || ConnectionPool.new(size: max_connections) do
          Redis.new(@redis_opts)
        end
        @prefix = opts[:prefix] || LaunchDarkly::Integrations::Redis::default_prefix
        @logger = opts[:logger] || Config.default_logger
        @test_hook = opts[:test_hook]  # used for unit tests, deliberately undocumented

        @stopped = Concurrent::AtomicBoolean.new(false)

        with_connection do |redis|
          @logger.info("RedisFeatureStore: using Redis instance at #{redis.connection[:host]}:#{redis.connection[:port]} \
  and prefix: #{@prefix}")
        end
      end

      def init_internal(all_data)
        count = 0
        with_connection do |redis|
          all_data.each do |kind, items|
            redis.multi do |multi|
              multi.del(items_key(kind))
              count = count + items.count
              items.each { |key, item|
                redis.hset(items_key(kind), key, item.to_json)
              }
            end
          end
        end
        @logger.info { "RedisFeatureStore: initialized with #{count} items" }
      end

      def get_internal(kind, key)
        with_connection do |redis|
          get_redis(redis, kind, key)
        end
      end

      def get_all_internal(kind)
        fs = {}
        with_connection do |redis|
          hashfs = redis.hgetall(items_key(kind))
          hashfs.each do |k, json_item|
            f = JSON.parse(json_item, symbolize_names: true)
            fs[k.to_sym] = f
          end
        end
        fs
      end

      def upsert_internal(kind, new_item)
        base_key = items_key(kind)
        key = new_item[:key]
        try_again = true
        final_item = new_item
        while try_again
          try_again = false
          with_connection do |redis|
            redis.watch(base_key) do
              old_item = get_redis(redis, kind, key)
              before_update_transaction(base_key, key)
              if old_item.nil? || old_item[:version] < new_item[:version]
                result = redis.multi do |multi|
                  multi.hset(base_key, key, new_item.to_json)
                end
                if result.nil?
                  @logger.debug { "RedisFeatureStore: concurrent modification detected, retrying" }
                  try_again = true
                end
              else
                final_item = old_item
                action = new_item[:deleted] ? "delete" : "update"
                @logger.warn { "RedisFeatureStore: attempted to #{action} #{key} version: #{old_item[:version]} \
in '#{kind[:namespace]}' with a version that is the same or older: #{new_item[:version]}" }
              end
              redis.unwatch
            end
          end
        end
        final_item
      end

      def initialized_internal?
        with_connection { |redis| redis.exists(items_key(FEATURES)) }
      end

      def stop
        if @stopped.make_true
          @pool.shutdown { |redis| redis.close }
        end
      end

      private

      # exposed for testing
      def before_update_transaction(base_key, key)
        @test_hook.before_update_transaction(base_key, key) if !@test_hook.nil?
      end

      def items_key(kind)
        @prefix + ":" + kind[:namespace]
      end

      def cache_key(kind, key)
        kind[:namespace] + ":" + key.to_s
      end

      def with_connection
        @pool.with { |redis| yield(redis) }
      end

      def get_redis(redis, kind, key)
        json_item = redis.hget(items_key(kind), key)
        json_item.nil? ? nil : JSON.parse(json_item, symbolize_names: true)
      end
    end

    private_constant :RedisFeatureStoreCore

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
      if !REDIS_ENABLED
        raise RuntimeError.new("can't use RedisFeatureStore because one of these gems is missing: redis, connection_pool")
      end

      @core = RedisFeatureStoreCore.new(opts)
      @wrapper = LaunchDarkly::Integrations::Helpers::CachingStoreWrapper.new(@core, opts)
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
