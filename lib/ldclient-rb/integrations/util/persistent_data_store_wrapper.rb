require "concurrent/atomics"

require "ldclient-rb/impl/expiring_cache"
require "ldclient-rb/interfaces"

module LaunchDarkly
  module Integrations
    #
    # Support code that may be helpful in creating integrations.
    #
    # @since 5.5.0
    #
    module Util
      #
      # Gives the SDK's {LaunchDarkly::Interfaces::FeatureStore} interface to a
      # {LaunchDarkly::Interfaces::PersistentDataStore}.
      #
      # The wrapper serializes the items that the SDK writes and deserializes the items that the
      # store returns. It removes deleted items from query results. It can also keep the items in
      # an in-memory cache, so that the SDK does not query the store for each flag evaluation.
      #
      # A database integration implements {LaunchDarkly::Interfaces::PersistentDataStore} and
      # gives the SDK a wrapper around its store.
      #
      # Cache behavior:
      #
      # - The wrapper caches each item that it reads, and each list of all items of a kind. It also
      #   caches an item that the store does not have, so that a query for a missing flag does not
      #   go to the store each time.
      # - After a successful write, the wrapper caches the item that the store has.
      # - If a write fails, the wrapper does not change the cache.
      # - After the store reports that it is initialized, the wrapper does not ask again. It caches
      #   a "not initialized" result until the cache entry expires.
      #
      class PersistentDataStoreWrapper
        include LaunchDarkly::Interfaces::FeatureStore

        #
        # Creates a wrapper around a persistent data store.
        #
        # @param core [LaunchDarkly::Interfaces::PersistentDataStore] the store
        # @param opts [Hash] options; the wrapper ignores options that it does not use
        # @option opts [Float] :expiration (15) the number of seconds to keep an item in the cache;
        #   0 or less means no cache
        # @option opts [Integer] :capacity (1000) the maximum number of entries in the cache
        # @option opts [Logger] :logger logs data validation problems in items from the store
        #
        def initialize(core, opts = {})
          @core = core
          @logger = opts[:logger]

          expiration_seconds = opts[:expiration] || 15
          if expiration_seconds > 0
            capacity = opts[:capacity] || 1000
            @cache = Impl::ExpiringCache.new(capacity, expiration_seconds)
          else
            @cache = nil
          end

          @inited = Concurrent::AtomicBoolean.new(false)
        end

        def monitoring_enabled?
          true
        end

        def available?
          @core.available?
        end

        def init(all_data)
          serialized = all_data.to_h do |kind, items|
            [kind, items.to_h { |key, item| [key, serialize(kind, item)] }]
          end

          begin
            @core.init(serialized)
          rescue
            @cache&.clear
            raise
          end

          cache = @cache
          unless cache.nil?
            cache.clear
            all_data.each do |kind, items|
              cache[all_cache_key(kind)] = items_if_not_deleted(items)
              items.each do |key, item|
                cache[item_cache_key(kind, key)] = [item]
              end
            end
          end

          @inited.make_true
        end

        def get(kind, key)
          cache = @cache
          cache_key = item_cache_key(kind, key)
          unless cache.nil?
            # An item entry is an array, so that the cache can keep a nil result.
            cached = cache[cache_key]
            return item_if_not_deleted(cached[0]) unless cached.nil?
          end

          item = deserialize(kind, key, @core.get(kind, key))
          cache[cache_key] = [item] unless cache.nil?
          item_if_not_deleted(item)
        end

        def all(kind)
          cache = @cache
          unless cache.nil?
            items = cache[all_cache_key(kind)]
            return items unless items.nil?
          end

          items = @core.get_all(kind).to_h do |key, descriptor|
            [key.to_sym, deserialize(kind, key, descriptor)]
          end
          items = items_if_not_deleted(items)
          cache[all_cache_key(kind)] = items unless cache.nil?
          items
        end

        def upsert(kind, item)
          key = item[:key]
          updated = @core.upsert(kind, key, serialize(kind, item)) == true

          cache = @cache
          unless cache.nil?
            cache.delete(all_cache_key(kind))
            if updated
              cache[item_cache_key(kind, key)] = [item]
            else
              refresh_cached_item(cache, kind, key)
            end
          end

          updated
        end

        def delete(kind, key, version)
          upsert(kind, { key: key, version: version, deleted: true })
        end

        def initialized?
          return true if @inited.value

          cache = @cache
          return false if !cache.nil? && cache[inited_cache_key] == false

          result = @core.initialized? == true
          if result
            @inited.make_true
            cache&.delete(inited_cache_key)
          elsif !cache.nil?
            cache[inited_cache_key] = false
          end
          result
        end

        #
        # Disables the in-memory cache. Later operations go to the store. It is safe to call this
        # method more than one time.
        #
        # The FDv2 data system calls this method after its in-memory store has the data. The
        # cache then has no use. This method is not part of the public API.
        #
        # @return [void]
        #
        def disable_cache
          cache = @cache
          return if cache.nil?
          @cache = nil
          cache.clear
        end

        def stop
          @core.stop
        end

        private

        def serialize(kind, item)
          LaunchDarkly::Interfaces::DataStore::SerializedItemDescriptor.new(
            version: item[:version],
            deleted: item[:deleted] == true,
            serialized_item: kind.serialize(item)
          )
        end

        def deserialize(kind, key, descriptor)
          return nil if descriptor.nil?
          if descriptor.serialized_item.nil?
            return { key: key.to_s, version: descriptor.version, deleted: true }
          end

          kind.deserialize(descriptor.serialized_item, @logger)
        end

        # After a write that the store did not apply, the store has a newer item than the cache.
        # If the read fails, the cache keeps its entry.
        def refresh_cached_item(cache, kind, key)
          cache[item_cache_key(kind, key)] = [deserialize(kind, key, @core.get(kind, key))]
        rescue
          nil
        end

        # One cache holds three types of entry. An item entry has a key like "features:my-flag".
        def item_cache_key(kind, key)
          kind.namespace + ":" + key.to_s
        end

        # A list of all items of a kind uses the kind as its key.
        def all_cache_key(kind)
          kind
        end

        # A "not initialized" result uses this key.
        def inited_cache_key
          "$inited"
        end

        def item_if_not_deleted(item)
          (item.nil? || item[:deleted]) ? nil : item
        end

        def items_if_not_deleted(items)
          items.reject { |_key, item| item[:deleted] }
        end
      end
    end
  end
end
