require "ldclient-rb/interfaces"
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
            unless REDIS_ENABLED
              raise RuntimeError.new("can't use #{description} because one of these gems is missing: redis, connection_pool")
            end

            @pool = create_redis_pool(opts)

            # shutdown pool on close unless the client passed a custom pool and specified not to shutdown
            @pool_shutdown_on_close = !opts[:pool] || opts.fetch(:pool_shutdown_on_close, true)

            @prefix = opts[:prefix] || LaunchDarkly::Integrations::Redis::default_prefix
            @logger = opts[:logger] || Config.default_logger
            @test_hook = opts[:test_hook]  # used for unit tests, deliberately undocumented

            @stopped = Concurrent::AtomicBoolean.new

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
        # The Redis implementation of {LaunchDarkly::Interfaces::PersistentDataStore}.
        #
        class RedisFeatureStoreCore < RedisStoreImplBase
          include LaunchDarkly::Interfaces::PersistentDataStore

          def initialize(opts)
            super(opts)

            @test_hook = opts[:test_hook]  # used for unit tests, deliberately undocumented
          end

          def available?
            # The result of the query does not matter. A successful query shows that Redis operates.
            initialized?
            true
          rescue
            false
          end

          def description
            "RedisFeatureStore"
          end

          def init(all_data)
            count = 0
            with_connection do |redis|
              redis.multi do |multi|
                all_data.each do |kind, items|
                  multi.del(items_key(kind))
                  count = count + items.count
                  items.each do |key, item|
                    multi.hset(items_key(kind), key, item.serialized_item)
                  end
                end
                multi.set(inited_key, inited_key)
              end
            end
            @logger.info { "RedisFeatureStore: initialized with #{count} items" }
          end

          def get(kind, key)
            with_connection do |redis|
              to_descriptor(redis.hget(items_key(kind), key))
            end
          end

          def get_all(kind)
            items = {}
            with_connection do |redis|
              redis.hgetall(items_key(kind)).each do |key, serialized|
                items[key.to_sym] = to_descriptor(serialized)
              end
            end
            items
          end

          def upsert(kind, key, item)
            base_key = items_key(kind)
            try_again = true
            updated = true
            while try_again
              try_again = false
              with_connection do |redis|
                redis.watch(base_key) do
                  old_serialized = redis.hget(base_key, key)
                  before_update_transaction(base_key, key)
                  old_version = old_serialized.nil? ? nil : kind.deserialize(old_serialized)[:version]
                  if old_version.nil? || old_version < item.version
                    result = redis.multi do |multi|
                      multi.hset(base_key, key, item.serialized_item)
                    end
                    if result.nil?
                      @logger.debug { "RedisFeatureStore: concurrent modification detected, retrying" }
                      try_again = true
                    end
                  else
                    updated = false
                    action = item.deleted ? "delete" : "update"
                    # rubocop:disable Layout/LineLength
                    @logger.warn { "RedisFeatureStore: attempted to #{action} #{key} version: #{old_version} in '#{kind.namespace}' with a version that is the same or older: #{item.version}" }
                  end
                  redis.unwatch
                end
              end
            end
            updated
          end

          def initialized?
            with_connection { |redis| redis.exists?(inited_key) }
          end

          private

          def before_update_transaction(base_key, key)
            @test_hook.before_update_transaction(base_key, key) unless @test_hook.nil?
          end

          def items_key(kind)
            @prefix + ":" + kind.namespace
          end

          def inited_key
            @prefix + ":$inited"
          end

          # Redis does not keep the version apart from the serialized item.
          def to_descriptor(serialized)
            return nil if serialized.nil?
            LaunchDarkly::Interfaces::DataStore::SerializedItemDescriptor.new(version: 0, deleted: false, serialized_item: serialized)
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
