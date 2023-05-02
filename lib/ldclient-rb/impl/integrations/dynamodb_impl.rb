require "json"

module LaunchDarkly
  module Impl
    module Integrations
      module DynamoDB
        class DynamoDBStoreImplBase
          begin
            require "aws-sdk-dynamodb"
            AWS_SDK_ENABLED = true
          rescue ScriptError, StandardError
            begin
              require "aws-sdk"
              AWS_SDK_ENABLED = true
            rescue ScriptError, StandardError
              AWS_SDK_ENABLED = false
            end
          end

          PARTITION_KEY = "namespace"
          SORT_KEY = "key"

          def initialize(table_name, opts)
            unless AWS_SDK_ENABLED
              raise RuntimeError.new("can't use #{description} without the aws-sdk or aws-sdk-dynamodb gem")
            end

            @table_name = table_name
            @prefix = opts[:prefix] ? (opts[:prefix] + ":") : ""
            @logger = opts[:logger] || Config.default_logger

            if !opts[:existing_client].nil?
              @client = opts[:existing_client]
            else
              @client = Aws::DynamoDB::Client.new(opts[:dynamodb_opts] || {})
            end

            @logger.info("#{description}: using DynamoDB table \"#{table_name}\"")
          end

          def stop
            # AWS client doesn't seem to have a close method
          end

          protected def description
            "DynamoDB"
          end
        end

        #
        # Internal implementation of the DynamoDB feature store, intended to be used with CachingStoreWrapper.
        #
        class DynamoDBFeatureStoreCore < DynamoDBStoreImplBase
          VERSION_ATTRIBUTE = "version"
          ITEM_JSON_ATTRIBUTE = "item"

          def initialize(table_name, opts)
            super(table_name, opts)
          end

          def description
            "DynamoDBFeatureStore"
          end

          def available?
            resp = get_item_by_keys(inited_key, inited_key)
            !resp.item.nil? && resp.item.length > 0
            true
          rescue
            false
          end

          def init_internal(all_data)
            # Start by reading the existing keys; we will later delete any of these that weren't in all_data.
            unused_old_keys = read_existing_keys(all_data.keys)

            requests = []
            num_items = 0

            # Insert or update every provided item
            all_data.each do |kind, items|
              items.values.each do |item|
                requests.push({ put_request: { item: marshal_item(kind, item) } })
                unused_old_keys.delete([ namespace_for_kind(kind), item[:key] ])
                num_items = num_items + 1
              end
            end

            # Now delete any previously existing items whose keys were not in the current data
            unused_old_keys.each do |tuple|
              del_item = make_keys_hash(tuple[0], tuple[1])
              requests.push({ delete_request: { key: del_item } })
            end

            # Now set the special key that we check in initialized_internal?
            inited_item = make_keys_hash(inited_key, inited_key)
            requests.push({ put_request: { item: inited_item } })

            DynamoDBUtil.batch_write_requests(@client, @table_name, requests)

            @logger.info { "Initialized table #{@table_name} with #{num_items} items" }
          end

          def get_internal(kind, key)
            resp = get_item_by_keys(namespace_for_kind(kind), key)
            unmarshal_item(kind, resp.item)
          end

          def get_all_internal(kind)
            items_out = {}
            req = make_query_for_kind(kind)
            while true
              resp = @client.query(req)
              resp.items.each do |item|
                item_out = unmarshal_item(kind, item)
                items_out[item_out[:key].to_sym] = item_out
              end
              break if resp.last_evaluated_key.nil? || resp.last_evaluated_key.length == 0
              req.exclusive_start_key = resp.last_evaluated_key
            end
            items_out
          end

          def upsert_internal(kind, new_item)
            encoded_item = marshal_item(kind, new_item)
            begin
              @client.put_item({
                table_name: @table_name,
                item: encoded_item,
                condition_expression: "attribute_not_exists(#namespace) or attribute_not_exists(#key) or :version > #version",
                expression_attribute_names: {
                  "#namespace" => PARTITION_KEY,
                  "#key" => SORT_KEY,
                  "#version" => VERSION_ATTRIBUTE,
                },
                expression_attribute_values: {
                  ":version" => new_item[:version],
                },
              })
              new_item
            rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
              # The item was not updated because there's a newer item in the database.
              # We must now read the item that's in the database and return it, so CachingStoreWrapper can cache it.
              get_internal(kind, new_item[:key])
            end
          end

          def initialized_internal?
            resp = get_item_by_keys(inited_key, inited_key)
            !resp.item.nil? && resp.item.length > 0
          end

          private

          def prefixed_namespace(base_str)
            @prefix + base_str
          end

          def namespace_for_kind(kind)
            prefixed_namespace(kind[:namespace])
          end

          def inited_key
            prefixed_namespace("$inited")
          end

          def make_keys_hash(namespace, key)
            {
              PARTITION_KEY => namespace,
              SORT_KEY => key,
            }
          end

          def make_query_for_kind(kind)
            {
              table_name: @table_name,
              consistent_read: true,
              key_conditions: {
                PARTITION_KEY => {
                  comparison_operator: "EQ",
                  attribute_value_list: [ namespace_for_kind(kind) ],
                },
              },
            }
          end

          def get_item_by_keys(namespace, key)
            @client.get_item({
              table_name: @table_name,
              key: make_keys_hash(namespace, key),
            })
          end

          def read_existing_keys(kinds)
            keys = Set.new
            kinds.each do |kind|
              req = make_query_for_kind(kind).merge({
                projection_expression: "#namespace, #key",
                expression_attribute_names: {
                  "#namespace" => PARTITION_KEY,
                  "#key" => SORT_KEY,
                },
              })
              while true
                resp = @client.query(req)
                resp.items.each do |item|
                  namespace = item[PARTITION_KEY]
                  key = item[SORT_KEY]
                  keys.add([ namespace, key ])
                end
                break if resp.last_evaluated_key.nil? || resp.last_evaluated_key.length == 0
                req.exclusive_start_key = resp.last_evaluated_key
              end
            end
            keys
          end

          def marshal_item(kind, item)
            make_keys_hash(namespace_for_kind(kind), item[:key]).merge({
              VERSION_ATTRIBUTE => item[:version],
              ITEM_JSON_ATTRIBUTE => Model.serialize(kind, item),
            })
          end

          def unmarshal_item(kind, item)
            return nil if item.nil? || item.length == 0
            json_attr = item[ITEM_JSON_ATTRIBUTE]
            raise RuntimeError.new("DynamoDB map did not contain expected item string") if json_attr.nil?
            Model.deserialize(kind, json_attr)
          end
        end

        class DynamoDBBigSegmentStore < DynamoDBStoreImplBase
          KEY_METADATA = 'big_segments_metadata'
          KEY_CONTEXT_DATA = 'big_segments_user'
          ATTR_SYNC_TIME = 'synchronizedOn'
          ATTR_INCLUDED = 'included'
          ATTR_EXCLUDED = 'excluded'

          def initialize(table_name, opts)
            super(table_name, opts)
          end

          def description
            "DynamoDBBigSegmentStore"
          end

          def get_metadata
            key = @prefix + KEY_METADATA
            data = @client.get_item(
              table_name: @table_name,
              key: {
                PARTITION_KEY => key,
                SORT_KEY => key,
              }
            )
            timestamp = data.item && data.item[ATTR_SYNC_TIME] ?
              data.item[ATTR_SYNC_TIME] : nil
            LaunchDarkly::Interfaces::BigSegmentStoreMetadata.new(timestamp)
          end

          def get_membership(context_hash)
            data = @client.get_item(
              table_name: @table_name,
              key: {
                PARTITION_KEY => @prefix + KEY_CONTEXT_DATA,
                SORT_KEY => context_hash,
              })
            return nil unless data.item
            excluded_refs = data.item[ATTR_EXCLUDED] || []
            included_refs = data.item[ATTR_INCLUDED] || []
            if excluded_refs.empty? && included_refs.empty?
              nil
            else
              membership = {}
              excluded_refs.each { |ref| membership[ref] = false }
              included_refs.each { |ref| membership[ref] = true }
              membership
            end
          end
        end

        class DynamoDBUtil
          #
          # Calls client.batch_write_item as many times as necessary to submit all of the given requests.
          # The requests array is consumed.
          #
          def self.batch_write_requests(client, table, requests)
            batch_size = 25
            while true
              chunk = requests.shift(batch_size)
              break if chunk.empty?
              client.batch_write_item({ request_items: { table => chunk } })
            end
          end
        end
      end
    end
  end
end
