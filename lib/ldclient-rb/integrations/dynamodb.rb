require "ldclient-rb/impl/integrations/dynamodb_impl"
require "ldclient-rb/integrations/util/store_wrapper"

module LaunchDarkly
  module Integrations
    module DynamoDB
      #
      # Creates a DynamoDB-backed persistent data store. For more details about how and why you can
      # use a persistent data store, see the
      # [SDK reference guide](https://docs.launchdarkly.com/v2.0/docs/using-a-persistent-feature-store).
      #
      # To use this method, you must first install one of the AWS SDK gems: either `aws-sdk-dynamodb`, or
      # the full `aws-sdk`. Then, put the object returned by this method into the `data_store` property
      # of your client configuration ({LaunchDarkly::Config}).
      #
      # @example Configuring the data store
      #     store = LaunchDarkly::Integrations::DynamoDB::new_data_store("my-table-name")
      #     config = LaunchDarkly::Config.new(data_store: store)
      #     client = LaunchDarkly::LDClient.new(my_sdk_key, config)
      #
      # Note that the specified table must already exist in DynamoDB. It must have a partition key called
      # "namespace", and a sort key called "key" (both strings). The SDK does not create the table
      # automatically because it has no way of knowing what additional properties (such as permissions
      # and throughput) you would want it to have.
      #
      # By default, the DynamoDB client will try to get your AWS credentials and region name from
      # environment variables and/or local configuration files, as described in the AWS SDK documentation.
      # You can also specify any supported AWS SDK options in `dynamodb_opts`-- or, provide an
      # already-configured DynamoDB client in `existing_client`.
      #
      # @param table_name [String] name of an existing DynamoDB table
      # @param opts [Hash] the configuration options
      # @option opts [Hash] :dynamodb_opts  options to pass to the DynamoDB client constructor (ignored if you specify `:existing_client`)
      # @option opts [Object] :existing_client  an already-constructed DynamoDB client for the data store to use
      # @option opts [String] :prefix  namespace prefix to add to all keys used by LaunchDarkly
      # @option opts [Logger] :logger  a `Logger` instance; defaults to `Config.default_logger`
      # @option opts [Integer] :expiration (15)  expiration time for the in-memory cache, in seconds; 0 for no local caching
      # @option opts [Integer] :capacity (1000)  maximum number of items in the cache
      # @return [LaunchDarkly::Interfaces::DataStore]  a data store object
      #
      def self.new_data_store(table_name, opts)
        core = LaunchDarkly::Impl::Integrations::DynamoDB::DynamoDBDataStoreCore.new(table_name, opts)
        return LaunchDarkly::Integrations::Util::CachingStoreWrapper.new(core, opts)
      end
    end
  end
end
