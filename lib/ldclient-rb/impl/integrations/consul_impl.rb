require "json"

module LaunchDarkly
  module Impl
    module Integrations
      module Consul
        #
        # The Consul implementation of {LaunchDarkly::Interfaces::PersistentDataStore}.
        #
        class ConsulFeatureStoreCore
          include LaunchDarkly::Interfaces::PersistentDataStore

          begin
            require "diplomat"
            require "ostruct"
            CONSUL_ENABLED = true
          rescue ScriptError, StandardError
            CONSUL_ENABLED = false
          end

          def initialize(opts)
            unless CONSUL_ENABLED
              raise RuntimeError.new("can't use Consul feature store without the 'diplomat' gem")
            end

            @prefix = (opts[:prefix] || LaunchDarkly::Integrations::Consul.default_prefix) + '/'
            @logger = opts[:logger] || Config.default_logger
            Diplomat.configuration = opts[:consul_config] unless opts[:consul_config].nil?
            Diplomat.configuration.url = opts[:url] unless opts[:url].nil?
            @logger.info("ConsulFeatureStore: using Consul host at #{Diplomat.configuration.url}")
          end

          def init(all_data)
            # Start by reading the existing keys; we will later delete any of these that weren't in all_data.
            unused_old_keys = Set.new
            keys = Diplomat::Kv.get(@prefix, { keys: true, recurse: true }, :return)
            unused_old_keys.merge(keys) if keys != ""

            ops = []
            num_items = 0

            # Insert or update every provided item
            all_data.each do |kind, items|
              items.each do |item_name, item|
                key = item_key(kind, item_name)
                ops.push({ 'KV' => { 'Verb' => 'set', 'Key' => key, 'Value' => item.serialized_item } })
                unused_old_keys.delete(key)
                num_items = num_items + 1
              end
            end

            # Now delete any previously existing items whose keys were not in the current data
            unused_old_keys.each do |key|
              ops.push({ 'KV' => { 'Verb' => 'delete', 'Key' => key } })
            end

            # Now set the special key that we check in initialized?
            ops.push({ 'KV' => { 'Verb' => 'set', 'Key' => inited_key, 'Value' => '' } })

            ConsulUtil.batch_operations(ops)

            @logger.info { "Initialized database with #{num_items} items" }
          end

          def get(kind, key)
            value = Diplomat::Kv.get(item_key(kind, key), {}, :return)  # :return means "don't throw an error if not found"
            (value.nil? || value == "") ? nil : to_descriptor(value)
          end

          def get_all(kind)
            items_out = {}
            prefix = kind_key(kind)
            Diplomat::Kv.get_all(prefix, {}, :return).each do |result|
              value = result[:value]
              next if value.nil?
              db_key = result[:key].to_s
              next unless db_key.start_with?(prefix)
              # Use the key that the item is stored under, not the key inside the item. A deleted
              # item (a "tombstone") is not guaranteed to carry a key of its own.
              items_out[db_key[prefix.length..].to_sym] = to_descriptor(value)
            end
            items_out
          end

          def upsert(kind, item_name, item)
            key = item_key(kind, item_name)

            # We will potentially keep retrying indefinitely until someone's write succeeds
            while true
              old_value = Diplomat::Kv.get(key, { decode_values: true }, :return)
              if old_value.nil? || old_value == ""
                mod_index = 0
              else
                old_item = kind.deserialize(old_value[0]["Value"])
                # Check whether the item is stale. If so, don't do the update.
                return false if old_item[:version] >= item.version
                mod_index = old_value[0]["ModifyIndex"]
              end

              # Otherwise, try to write. We will do a compare-and-set operation, so the write will only succeed if
              # the key's ModifyIndex is still equal to the previous value. If the previous ModifyIndex was zero,
              # it means the key did not previously exist and the write will only succeed if it still doesn't exist.
              success = Diplomat::Kv.put(key, item.serialized_item, cas: mod_index)
              return true if success

              # If we failed, retry the whole shebang
              @logger.debug { "Concurrent modification detected, retrying" }
            end
          end

          def initialized?
            # Unfortunately we need to use exceptions here, instead of the :return parameter, because with
            # :return there's no way to distinguish between a missing value and an empty string.
            begin
              Diplomat::Kv.get(inited_key, {})
              true
            rescue Diplomat::KeyNotFound
              false
            end
          end

          def available?
            # Most implementations use the initialized? method as a
            # proxy for this check. However, since `initialized?`
            # catches a KeyNotFound exception, and that exception can be raised
            # when the server goes away, we have to modify our behavior
            # slightly.
            Diplomat::Kv.get(inited_key, {}, :return, :return)
            true
          rescue
            false
          end

          def stop
            # There's no Consul client instance to dispose of
          end

          private

          def item_key(kind, key)
            kind_key(kind) + key.to_s
          end

          def kind_key(kind)
            @prefix + kind.namespace + '/'
          end

          # Consul does not keep the version apart from the serialized item.
          def to_descriptor(serialized)
            LaunchDarkly::Interfaces::DataStore::SerializedItemDescriptor.new(version: 0, deleted: false, serialized_item: serialized)
          end

          def inited_key
            @prefix + '$inited'
          end
        end

        class ConsulUtil
          #
          # Submits as many transactions as necessary to submit all of the given operations.
          # The ops array is consumed.
          #
          def self.batch_operations(ops)
            batch_size = 64  # Consul can only do this many at a time
            while true
              chunk = ops.shift(batch_size)
              break if chunk.empty?
              Diplomat::Kv.txn(chunk)
            end
          end
        end
      end
    end
  end
end
