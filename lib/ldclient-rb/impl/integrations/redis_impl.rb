require "concurrent/atomics"
require "json"

module LaunchDarkly
  module Impl
    module Integrations
      module Redis
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
          # @option opts [Integer] :expiration  expiration time for the in-memory cache, in seconds; 0 for no local caching
          # @option opts [Integer] :capacity  maximum number of feature flags (or related objects) to cache locally
          # @option opts [Object] :pool  custom connection pool, if desired
          # @option opts [Boolean] :pool_shutdown_on_close whether calling `close` should shutdown the custom connection pool.
          #
          def initialize(opts = {})
            core = RedisFeatureStoreCore.new(opts)
            @wrapper = LaunchDarkly::Integrations::Util::CachingStoreWrapper.new(core, opts)
          end

          def monitoring_enabled?
            true
          end

          def available?
            @wrapper.available?
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

        class RedisStoreImplBase
          begin
            require "redis"
            require "connection_pool"
            REDIS_ENABLED = true
          rescue ScriptError, StandardError
            REDIS_ENABLED = false
          end

          def initialize(opts)
            unless REDIS_ENABLED
              raise RuntimeError.new("can't use #{description} because one of these gems is missing: redis, connection_pool")
            end

            @pool = create_redis_pool(opts)

            # shutdown pool on close unless the client passed a custom pool and specified not to shutdown
            @pool_shutdown_on_close = (!opts[:pool] || opts.fetch(:pool_shutdown_on_close, true))

            @prefix = opts[:prefix] || LaunchDarkly::Integrations::Redis::default_prefix
            @logger = opts[:logger] || Config.default_logger
            @test_hook = opts[:test_hook]  # used for unit tests, deliberately undocumented

            @stopped = Concurrent::AtomicBoolean.new()

            with_connection do |redis|
              @logger.info("#{description}: using Redis instance at #{redis.connection[:host]}:#{redis.connection[:port]} and prefix: #{@prefix}")
            end
          end

          def stop
            if @stopped.make_true
              return unless @pool_shutdown_on_close
              @pool.shutdown { |redis| redis.close }
            end
          end

          protected def description
            "Redis"
          end

          protected def with_connection
            @pool.with { |redis| yield(redis) }
          end

          private def create_redis_pool(opts)
            redis_opts = opts[:redis_opts] ? opts[:redis_opts].clone : Hash.new
            if opts[:redis_url]
              redis_opts[:url] = opts[:redis_url]
            end
            unless redis_opts.include?(:url)
              redis_opts[:url] = LaunchDarkly::Integrations::Redis::default_redis_url
            end
            max_connections = opts[:max_connections] || 16
            opts[:pool] || ConnectionPool.new(size: max_connections) { ::Redis.new(redis_opts) }
          end
        end

        #
        # Internal implementation of the Redis feature store, intended to be used with CachingStoreWrapper.
        #
        class RedisFeatureStoreCore < RedisStoreImplBase
          def initialize(opts)
            super(opts)

            @test_hook = opts[:test_hook]  # used for unit tests, deliberately undocumented
          end

          def available?
            # We don't care what the status is, only that we can connect
            initialized_internal?
            true
          rescue
            false
          end

          def description
            "RedisFeatureStore"
          end

          def init_internal(all_data)
            count = 0
            with_connection do |redis|
              redis.multi do |multi|
                all_data.each do |kind, items|
                  multi.del(items_key(kind))
                  count = count + items.count
                  items.each do |key, item|
                    multi.hset(items_key(kind), key, Model.serialize(kind,item))
                  end
                end
                multi.set(inited_key, inited_key)
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
                fs[k.to_sym] = Model.deserialize(kind, json_item)
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
                      multi.hset(base_key, key, Model.serialize(kind, new_item))
                    end
                    if result.nil?
                      @logger.debug { "RedisFeatureStore: concurrent modification detected, retrying" }
                      try_again = true
                    end
                  else
                    final_item = old_item
                    action = new_item[:deleted] ? "delete" : "update"
                    # rubocop:disable Layout/LineLength
                    @logger.warn { "RedisFeatureStore: attempted to #{action} #{key} version: #{old_item[:version]} in '#{kind[:namespace]}' with a version that is the same or older: #{new_item[:version]}" }
                  end
                  redis.unwatch
                end
              end
            end
            final_item
          end

          def initialized_internal?
            with_connection { |redis| redis.exists?(inited_key) }
          end

          private

          def before_update_transaction(base_key, key)
            @test_hook.before_update_transaction(base_key, key) unless @test_hook.nil?
          end

          def items_key(kind)
            @prefix + ":" + kind[:namespace]
          end

          def cache_key(kind, key)
            kind[:namespace] + ":" + key.to_s
          end

          def inited_key
            @prefix + ":$inited"
          end

          def get_redis(redis, kind, key)
            Model.deserialize(kind, redis.hget(items_key(kind), key))
          end
        end

        #
        # Internal implementation of the Redis big segment store.
        #
        class RedisBigSegmentStore < RedisStoreImplBase
          KEY_LAST_UP_TO_DATE = ':big_segments_synchronized_on'
          KEY_CONTEXT_INCLUDE = ':big_segment_include:'
          KEY_CONTEXT_EXCLUDE = ':big_segment_exclude:'

          def description
            "RedisBigSegmentStore"
          end

          def get_metadata
            value = with_connection { |redis| redis.get(@prefix + KEY_LAST_UP_TO_DATE) }
            Interfaces::BigSegmentStoreMetadata.new(value.nil? ? nil : value.to_i)
          end

          def get_membership(context_hash)
            with_connection do |redis|
              included_refs = redis.smembers(@prefix + KEY_CONTEXT_INCLUDE + context_hash)
              excluded_refs = redis.smembers(@prefix + KEY_CONTEXT_EXCLUDE + context_hash)
              if !included_refs && !excluded_refs
                nil
              else
                membership = {}
                excluded_refs.each { |ref| membership[ref] = false }
                included_refs.each { |ref| membership[ref] = true }
                membership
              end
            end
          end
        end
      end
    end
  end
end
