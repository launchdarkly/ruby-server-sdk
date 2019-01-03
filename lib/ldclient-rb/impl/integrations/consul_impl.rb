require "json"

module LaunchDarkly
  module Impl
    module Integrations
      module Consul
        #
        # Internal implementation of the Consul feature store, intended to be used with CachingStoreWrapper.
        #
        class ConsulFeatureStoreCore
          begin
            require "diplomat"
            CONSUL_ENABLED = true
          rescue ScriptError, StandardError
            CONSUL_ENABLED = false
          end

          def initialize(opts)
            if !CONSUL_ENABLED
              raise RuntimeError.new("can't use Consul feature store without the 'diplomat' gem")
            end

            @prefix = (opts[:prefix] || LaunchDarkly::Integrations::Consul.default_prefix) + '/'
            @logger = opts[:logger] || Config.default_logger
            @client = Diplomat::Kv.new(configuration: opts[:consul_config])
            
            @logger.info("ConsulFeatureStore: using Consul host at #{Diplomat.configuration.url}")
          end

          def init_internal(all_data)
            # Start by reading the existing keys; we will later delete any of these that weren't in all_data.
            unused_old_keys = set()
            unused_old_keys.merge(@client.get(@prefix, keys: true, recurse: true))

            ops = []
            num_items = 0

            # Insert or update every provided item
            all_data.each do |kind, items|
              items.values.each do |item|
                value = item.to_json
                key = item_key(kind, item[:key])
                ops.push({ 'KV' => { 'Verb' => 'set', 'Key' => key, 'Value' => value } })
                unused_old_keys.delete(key)
                num_items = num_items + 1
              end
            end

            # Now delete any previously existing items whose keys were not in the current data
            unused_old_keys.each do |tuple|
              ops.push({ 'KV' => { 'Verb' => 'delete', 'Key' => key } })
            end
    
            # Now set the special key that we check in initialized_internal?
            ops.push({ 'KV' => { 'Verb' => 'set', 'Key' => key, 'Value' => '' } })
            
            ConsulUtil.batch_operations(ops)

            @logger.info { "Initialized database with #{num_items} items" }
          end

          def get_internal(kind, key)

            resp = get_item_by_keys(namespace_for_kind(kind), key)
            unmarshal_item(resp.item)
          end

          def get_all_internal(kind)
            items_out = {}
            
            items_out
          end

          def upsert_internal(kind, new_item)
            
          end

          def initialized_internal?
            
          end

          def stop
            # There's no way to close the Consul client
          end

          private

          def item_key(kind, key)
            kind_key(kind) + '/' + key
          end

          def kind_key(kind)
            @prefix + kind[:namespace]
          end
          
          def inited_key
            @prefix + '$inited'
          end

          def marshal_item(kind, item)
            make_keys_hash(namespace_for_kind(kind), item[:key]).merge({
              VERSION_ATTRIBUTE => item[:version],
              ITEM_JSON_ATTRIBUTE => item.to_json
            })
          end

          def unmarshal_item(item)
            return nil if item.nil? || item.length == 0
            json_attr = item[ITEM_JSON_ATTRIBUTE]
            raise RuntimeError.new("DynamoDB map did not contain expected item string") if json_attr.nil?
            JSON.parse(json_attr, symbolize_names: true)
          end
        end

        class ConsulUtil
          #
          # Submits as many transactions as necessary to submit all of the given operations.
          # The ops array is consumed.
          #
          def self.batch_write_requests(ops)
            batch_size = 64 # Consul can only do this many at a time
            while true
              chunk = requests.shift(batch_size)
              break if chunk.empty?
              Diplomat::Kv.txn(chunk)
            end
          end
        end
      end
    end
  end
end
