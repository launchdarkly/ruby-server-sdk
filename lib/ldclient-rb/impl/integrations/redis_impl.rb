require "concurrent/atomics"
require "json"

module LaunchDarkly
  module Impl
    module Integrations
      module Redis
        class RedisStoreImplBase
          begin
            require "redis"
            require "connection_pool"
            REDIS_ENABLED = true
          rescue ScriptError, StandardError
            REDIS_ENABLED = false
          end

          def initialize(opts)
            if !REDIS_ENABLED
              raise RuntimeError.new("can't use #{description} because one of these gems is missing: redis, connection_pool")
            end

            @pool = create_redis_pool(opts)

            # shutdown pool on close unless the client passed a custom pool and specified not to shutdown
            @pool_shutdown_on_close = (!opts[:pool] || opts.fetch(:pool_shutdown_on_close, true))

            @prefix = opts[:prefix] || LaunchDarkly::Integrations::Redis::default_prefix
            @logger = opts[:logger] || Config.default_logger
            @test_hook = opts[:test_hook]  # used for unit tests, deliberately undocumented

            @stopped = Concurrent::AtomicBoolean.new(false)

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
            if !redis_opts.include?(:url)
              redis_opts[:url] = LaunchDarkly::Integrations::Redis::default_redis_url
            end
            max_connections = opts[:max_connections] || 16
            return opts[:pool] || ConnectionPool.new(size: max_connections) do
              ::Redis.new(redis_opts)
            end
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
            @test_hook.before_update_transaction(base_key, key) if !@test_hook.nil?
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
          KEY_USER_INCLUDE = ':big_segment_include:'
          KEY_USER_EXCLUDE = ':big_segment_exclude:'

          def description
            "RedisBigSegmentStore"
          end

          def get_metadata
            value = with_connection { |redis| redis.get(@prefix + KEY_LAST_UP_TO_DATE) }
            Interfaces::BigSegmentStoreMetadata.new(value.nil? ? nil : value.to_i)
          end

          def get_membership(user_hash)
            with_connection do |redis|
              included_refs = redis.smembers(@prefix + KEY_USER_INCLUDE + user_hash)
              excluded_refs = redis.smembers(@prefix + KEY_USER_EXCLUDE + user_hash)
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
