require "big_segment_store_spec_base"
require "feature_store_spec_base"
require "aws-sdk-dynamodb"
require "spec_helper"

# These tests will all fail if there isn't a local DynamoDB instance running.
# They can be disabled with LD_SKIP_DATABASE_TESTS=1

$DynamoDBBigSegmentStore = LaunchDarkly::Impl::Integrations::DynamoDB::DynamoDBBigSegmentStore

class DynamoDBStoreTester
  TABLE_NAME = 'LD_DYNAMODB_TEST_TABLE'
  DYNAMODB_OPTS = {
    credentials: Aws::Credentials.new("key", "secret"),
    region: "us-east-1",
    endpoint: "http://localhost:8000",
  }
  FEATURE_STORE_BASE_OPTS = {
    dynamodb_opts: DYNAMODB_OPTS,
    prefix: 'testprefix',
    logger: $null_log,
  }

  def initialize(options = {})
    @options = options.clone
    @options[:dynamodb_opts] = DYNAMODB_OPTS
    @actual_prefix = options[:prefix] ? "#{options[:prefix]}:" : ""
  end

  def self.create_test_client
    Aws::DynamoDB::Client.new(DYNAMODB_OPTS)
  end

  def self.create_table_if_necessary
    client = create_test_client
    begin
      client.describe_table({ table_name: TABLE_NAME })
      return  # no error, table exists
    rescue Aws::DynamoDB::Errors::ResourceNotFoundException
      # fall through to code below - we'll create the table
    end

    req = {
      table_name: TABLE_NAME,
      key_schema: [
        { attribute_name: "namespace", key_type: "HASH" },
        { attribute_name: "key", key_type: "RANGE" },
      ],
      attribute_definitions: [
        { attribute_name: "namespace", attribute_type: "S" },
        { attribute_name: "key", attribute_type: "S" },
      ],
      provisioned_throughput: {
        read_capacity_units: 1,
        write_capacity_units: 1,
      },
    }
    client.create_table(req)

    # When DynamoDB creates a table, it may not be ready to use immediately
  end

  def clear_data
    client = self.class.create_test_client
    items_to_delete = []
    req = {
      table_name: TABLE_NAME,
      projection_expression: '#namespace, #key',
      expression_attribute_names: {
        '#namespace' => 'namespace',
        '#key' => 'key',
      },
    }
    while true
      resp = client.scan(req)
      resp.items.each do |item|
        if !@actual_prefix || item["namespace"].start_with?(@actual_prefix)
          items_to_delete.push(item)
        end
      end
      break if resp.last_evaluated_key.nil? || resp.last_evaluated_key.length == 0
      req.exclusive_start_key = resp.last_evaluated_key
    end
    requests = items_to_delete.map do |item|
      { delete_request: { key: item } }
    end
    LaunchDarkly::Impl::Integrations::DynamoDB::DynamoDBUtil.batch_write_requests(client, TABLE_NAME, requests)
  end

  def create_feature_store
    LaunchDarkly::Integrations::DynamoDB::new_feature_store(TABLE_NAME, @options)
  end

  def create_big_segment_store
    LaunchDarkly::Integrations::DynamoDB::new_big_segment_store(TABLE_NAME, @options)
  end

  def set_big_segments_metadata(metadata)
    client = self.class.create_test_client
    key = @actual_prefix + $DynamoDBBigSegmentStore::KEY_METADATA
    client.put_item(
      table_name: TABLE_NAME,
      item: {
        "namespace" => key,
        "key" => key,
        $DynamoDBBigSegmentStore::ATTR_SYNC_TIME => metadata.last_up_to_date,
      }
    )
  end

  def set_big_segments(user_hash, includes, excludes)
    client = self.class.create_test_client
    sets = {
      $DynamoDBBigSegmentStore::ATTR_INCLUDED => Set.new(includes),
      $DynamoDBBigSegmentStore::ATTR_EXCLUDED => Set.new(excludes),
    }
    sets.each do |attr_name, values|
      if !values.empty?
        client.update_item(
          table_name: TABLE_NAME,
          key: {
            "namespace" => @actual_prefix + $DynamoDBBigSegmentStore::KEY_USER_DATA,
            "key" => user_hash,
          },
          update_expression: "ADD #{attr_name} :value",
          expression_attribute_values: {
            ":value" => values,
          }
        )
      end
    end
  end
end


describe "DynamoDB feature store" do
  break if ENV['LD_SKIP_DATABASE_TESTS'] == '1'

  DynamoDBStoreTester.create_table_if_necessary

  include_examples "persistent_feature_store", DynamoDBStoreTester
end

describe "DynamoDB big segment store" do
  break if ENV['LD_SKIP_DATABASE_TESTS'] == '1'

  DynamoDBStoreTester.create_table_if_necessary

  include_examples "big_segment_store", DynamoDBStoreTester
end
