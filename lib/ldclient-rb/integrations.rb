require "concurrent/atomics"

module LaunchDarkly
  #
  # Tools for connecting the LaunchDarkly client to other software.
  #
  module Integrations
    #
    # Integration with [Redis](https://redis.io/).
    #
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

    #
    # Support code that may be useful for integrations.
    #
    module Util
      #
      # CachingStoreWrapper is a partial implementation of the {LaunchDarkly::Interfaces::FeatureStore}
      # pattern that delegates part of its behavior to another object, while providing optional caching
      # behavior and other logic that would otherwise be repeated in every feature store implementation.
      # This makes it easier to create new database integrations by implementing only the database-specific
      # logic.
      #
      # The mixin {FeatureStoreCore} describes the methods that need to be supported by the inner
      # implementation object.
      #
      class CachingStoreWrapper
        include LaunchDarkly::Interfaces::FeatureStore
        
        #
        # Creates a new store wrapper instance.
        #
        # @param core [Object]  an object that implements the {FeatureStoreCore} methods
        # @param opts [Hash]  a hash that may include cache-related options; all others will be ignored
        # @option opts [Float] :expiration_seconds (15)  cache TTL; zero means no caching
        # @option opts [Integer] :capacity (1000)  maximum number of items in the cache
        #
        def initialize(core, opts)
          @core = core

          expiration_seconds = opts[:expiration] || 15
          if expiration_seconds > 0
            capacity = opts[:capacity] || 1000
            @cache = ExpiringCache.new(capacity, expiration_seconds)
          else
            @cache = nil
          end

          @inited = Concurrent::AtomicBoolean.new(false)
        end

        def init(all_data)
          @core.init_internal(all_data)
          @inited.make_true

          if !@cache.nil?
            @cache.clear
            all_data.each do |kind, items|
              @cache[kind] = items_if_not_deleted(items)
              items.each do |key, item|
                @cache[item_cache_key(kind, key)] = [item]
              end
            end
          end
        end

        def get(kind, key)
          if !@cache.nil?
            cache_key = item_cache_key(kind, key)
            cached = @cache[cache_key] # note, item entries in the cache are wrapped in an array so we can cache nil values
            return item_if_not_deleted(cached[0]) if !cached.nil?
          end

          item = @core.get_internal(kind, key)

          if !@cache.nil?
            @cache[cache_key] = [item]
          end

          item_if_not_deleted(item)
        end

        def all(kind)
          if !@cache.nil?
            items = @cache[all_cache_key(kind)]
            return items if !items.nil?
          end

          items = items_if_not_deleted(@core.get_all_internal(kind))
          @cache[all_cache_key(kind)] = items if !@cache.nil?
          items
        end

        def upsert(kind, item)
          new_state = @core.upsert_internal(kind, item)

          if !@cache.nil?
            @cache[item_cache_key(kind, item[:key])] = [new_state]
            @cache.delete(all_cache_key(kind))
          end
        end

        def delete(kind, key, version)
          upsert(kind, { key: key, version: version, deleted: true })
        end

        def initialized?
          return true if @inited.value

          if @cache.nil?
            result = @core.initialized_internal?
          else
            result = @cache[inited_cache_key]
            if result.nil?
              result = @core.initialized_internal?
              @cache[inited_cache_key] = result
            end
          end

          @inited.make_true if result
          result
        end

        def stop
          @core.stop
        end

        private

        # We use just one cache for 3 kinds of objects. Individual entities use a key like 'features:my-flag'.
        def item_cache_key(kind, key)
          kind[:namespace] + ":" + key.to_s
        end

        # The result of a call to get_all_internal is cached using the "kind" object as a key.
        def all_cache_key(kind)
          kind
        end

        # The result of initialized_internal? is cached using this key.
        def inited_cache_key
          "$inited"
        end

        def item_if_not_deleted(item)
          (item.nil? || item[:deleted]) ? nil : item
        end

        def items_if_not_deleted(items)
          items.select { |key, item| !item[:deleted] }
        end
      end

      #
      # This module describes the methods that you must implement on your own object in order to
      # use {CachingStoreWrapper}.
      #
      module FeatureStoreCore
        #
        # Initializes the store. This is the same as {LaunchDarkly::Interfaces::FeatureStore#init},
        # but the wrapper will take care of updating the cache if caching is enabled.
        #
        # @param all_data [Hash]  a hash where each key is one of the data kind objects, and each
        #   value is in turn a hash of string keys to entities
        #
        def init_internal(all_data)
        end

        #
        # Retrieves a single entity. This is the same as {LaunchDarkly::Interfaces::FeatureStore#get}
        # except that 1. the wrapper will take care of filtering out deleted entities by checking the
        # `:deleted` property, so you can just return exactly what was in the data store, and 2. the
        # wrapper will take care of checking and updating the cache if caching is enabled.
        #
        # @param kind [Object]  the kind of entity to get
        # @param key [String]  the unique key of the entity to get
        # @return [Hash]  the entity; nil if the key was not found
        #
        def get_internal(kind, key)
        end

        #
        # Retrieves all entities of the specified kind. This is the same as {LaunchDarkly::Interfaces::FeatureStore#all}
        # except that 1. the wrapper will take care of filtering out deleted entities by checking the
        # `:deleted` property, so you can just return exactly what was in the data store, and 2. the
        # wrapper will take care of checking and updating the cache if caching is enabled.
        #
        # @param kind [Object]  the kind of entity to get
        # @return [Hash]  a hash where each key is the entity's `:key` property and each value
        #   is the entity
        #
        def get_all_internal(kind)
        end

        #
        # Attempts to add or update an entity. This is the same as {LaunchDarkly::Interfaces::FeatureStore#upsert}
        # except that 1. the wrapper will take care of updating the cache if caching is enabled, and 2.
        # the method is expected to return the final state of the entity (i.e. either the `item`
        # parameter if the update succeeded, or the previously existing entity in the store if the
        # update failed; this is used for the caching logic).
        #
        # Note that FeatureStoreCore does not have a `delete` method. This is because {CachingStoreWrapper}
        # implements `delete` by simply calling `upsert` with an item whose `:deleted` property is true.
        #
        # @param kind [Object]  the kind of entity to add or update
        # @param item [Hash]  the entity to add or update
        # @return [Hash]  the entity as it now exists in the store after the update
        #
        def upsert_internal(kind, item)
        end

        #
        # Checks whether this store has been initialized. This is the same as
        # {LaunchDarkly::Interfaces::FeatureStore#initialized?} except that there is less of a concern
        # for efficiency, because the wrapper will use caching and memoization in order to call the method
        # as little as possible.
        #
        # @return [Boolean]  true if the store is in an initialized state
        #
        def initialized_internal?
        end

        #
        # Performs any necessary cleanup to shut down the store when the client is being shut down.
        #
        def stop
        end
      end
    end
  end
end
