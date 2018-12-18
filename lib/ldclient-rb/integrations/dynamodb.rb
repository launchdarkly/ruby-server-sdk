require "ldclient-rb/impl/integrations/dynamodb_impl"
require "ldclient-rb/integrations/util/store_wrapper"

module LaunchDarkly
  module Integrations
    module DynamoDB
      #
      # Creates a DynamoDB-backed persistent feature store.
      #
      # To use this method, you must first install one of the AWS SDK gems: either `aws-sdk-dynamodb`, or
      # the full `aws-sdk`. Then, put the object returned by this method into the `feature_store` property
      # of your client configuration ({LaunchDarkly::Config}).
      #
      # @param opts [Hash] the configuration options
      # @option opts [Hash] :dynamodb_opts  options to pass to the DynamoDB client constructor (ignored if you specify `:existing_client`)
      # @option opts [Object] :existing_client  an already-constructed DynamoDB client for the feature store to use
      # @option opts [String] :prefix  namespace prefix to add to all keys used by LaunchDarkly
      # @option opts [Logger] :logger  a `Logger` instance; defaults to `Config.default_logger`
      # @option opts [Integer] :expiration_seconds (15)  expiration time for the in-memory cache, in seconds; 0 for no local caching
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
