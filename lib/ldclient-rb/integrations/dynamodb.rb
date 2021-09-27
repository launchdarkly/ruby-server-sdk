require "ldclient-rb/impl/integrations/dynamodb_impl"
require "ldclient-rb/integrations/util/store_wrapper"

module LaunchDarkly
  module Integrations
    module DynamoDB
      #
      # Creates a DynamoDB-backed persistent feature store. For more details about how and why you can
      # use a persistent feature store, see the
      # [SDK reference guide](https://docs.launchdarkly.com/sdk/features/storing-data#ruby).
      #
      # To use this method, you must first install one of the AWS SDK gems: either `aws-sdk-dynamodb`, or
      # the full `aws-sdk`. Then, put the object returned by this method into the `feature_store` property
      # of your client configuration ({LaunchDarkly::Config}).
      #
      # @example Configuring the feature store
      #     store = LaunchDarkly::Integrations::DynamoDB::new_feature_store("my-table-name")
      #     config = LaunchDarkly::Config.new(feature_store: store)
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
      # @option opts [Object] :existing_client  an already-constructed DynamoDB client for the feature store to use
      # @option opts [String] :prefix  namespace prefix to add to all keys used by LaunchDarkly
      # @option opts [Logger] :logger  a `Logger` instance; defaults to `Config.default_logger`
      # @option opts [Integer] :expiration (15)  expiration time for the in-memory cache, in seconds; 0 for no local caching
      # @option opts [Integer] :capacity (1000)  maximum number of items in the cache
      # @return [LaunchDarkly::Interfaces::FeatureStore]  a feature store object
      #
      def self.new_feature_store(table_name, opts)
        core = LaunchDarkly::Impl::Integrations::DynamoDB::DynamoDBFeatureStoreCore.new(table_name, opts)
        return LaunchDarkly::Integrations::Util::CachingStoreWrapper.new(core, opts)
      end
    end
  end
end
