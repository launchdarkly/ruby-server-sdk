require "feature_store_spec_base"
require "aws-sdk-dynamodb"
require "spec_helper"


$table_name = 'LD_DYNAMODB_TEST_TABLE'
$endpoint = 'http://localhost:8000'
$my_prefix = 'testprefix'
$null_log = ::Logger.new($stdout)
$null_log.level = ::Logger::FATAL

$dynamodb_opts = {
  credentials: Aws::Credentials.new("key", "secret"),
  region: "us-east-1",
  endpoint: $endpoint
}

$base_opts = {
  dynamodb_opts: $dynamodb_opts,
  prefix: $my_prefix,
  logger: $null_log
}

def create_dynamodb_store(opts = {})
  LaunchDarkly::Integrations::DynamoDB::new_feature_store($table_name,
    opts.merge($base_opts).merge({ expiration: 60 }))
end

def create_dynamodb_store_uncached(opts = {})
  LaunchDarkly::Integrations::DynamoDB::new_feature_store($table_name,
    opts.merge($base_opts).merge({ expiration: 0 }))
end

def create_table_if_necessary
  client = create_test_client
  begin
    client.describe_table({ table_name: $table_name })
    return  # no error, table exists
  rescue Aws::DynamoDB::Errors::ResourceNotFoundException
    # fall through to code below - we'll create the table
  end

  req = {
    table_name: $table_name,
    key_schema: [
      { attribute_name: "namespace", key_type: "HASH" },
      { attribute_name: "key", key_type: "RANGE" }
    ],
    attribute_definitions: [
      { attribute_name: "namespace", attribute_type: "S" },
      { attribute_name: "key", attribute_type: "S" }
    ]
  }
  client.create_table(req)

  # When DynamoDB creates a table, it may not be ready to use immediately
end

def create_test_client
  Aws::DynamoDB::Client.new($dynamodb_opts)
end


describe "DynamoDB feature store" do
  
  # These tests will all fail if there isn't a local DynamoDB instance running.
  
  create_table_if_necessary

  context "with local cache" do
    include_examples "feature_store", method(:create_dynamodb_store)
  end

  context "without local cache" do
    include_examples "feature_store", method(:create_dynamodb_store_uncached)
  end
end
