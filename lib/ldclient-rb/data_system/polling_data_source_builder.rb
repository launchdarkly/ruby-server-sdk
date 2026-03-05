# frozen_string_literal: true

require "ldclient-rb/data_system/data_source_builder_common"

module LaunchDarkly
  module DataSystem
    #
    # Interface for custom polling requesters.
    #
    # A Requester is responsible for fetching data from a data source. The SDK
    # ships with built-in HTTP requesters for both FDv2 and FDv1 polling endpoints,
    # but you can implement this interface to provide custom data fetching logic
    # (e.g., reading from a file, a database, or a custom API).
    #
    # == Implementing a Custom Requester
    #
    # To create a custom requester, include this module and implement the {#fetch}
    # method:
    #
    #   class MyCustomRequester
    #     include LaunchDarkly::DataSystem::Requester
    #
    #     def fetch(selector)
    #       # Fetch data and return a Result containing [ChangeSet, headers]
    #       # ...
    #       LaunchDarkly::Result.success([change_set, {}])
    #     end
    #
    #     def stop
    #       # Clean up resources
    #     end
    #   end
    #
    #   polling = LaunchDarkly::DataSystem.polling_ds_builder
    #     .requester(MyCustomRequester.new)
    #
    # @see PollingDataSourceBuilder#requester
    #
    module Requester
      #
      # Fetches data for the given selector.
      #
      # @param selector [LaunchDarkly::Interfaces::DataSystem::Selector, nil]
      #   The selector describing what data to fetch. May be nil if no
      #   selector is available (e.g., on the first request).
      # @return [LaunchDarkly::Result] A Result containing a tuple of
      #   [ChangeSet, headers] on success, or an error message on failure.
      #
      def fetch(selector)
        raise NotImplementedError
      end

      #
      # Releases any resources held by this requester (e.g., persistent HTTP
      # connections). Called when the requester is no longer needed.
      #
      # Implementations should handle being called multiple times gracefully.
      # The default implementation is a no-op.
      #
      def stop
        # Optional - implementations may override if they need cleanup
      end
    end

    #
    # Builder for a polling data source that communicates with LaunchDarkly's
    # FDv2 polling endpoint.
    #
    # This builder can be used with {ConfigBuilder#initializers} or
    # {ConfigBuilder#synchronizers} to create custom data system configurations.
    #
    # The polling data source periodically fetches data from LaunchDarkly. It
    # supports conditional requests via ETags, so subsequent polls after the
    # initial request only transfer data if changes have occurred.
    #
    # == Example
    #
    #   polling = LaunchDarkly::DataSystem.polling_ds_builder
    #     .poll_interval(60)
    #     .base_uri("https://custom-endpoint.example.com")
    #
    #   data_system = LaunchDarkly::DataSystem.custom
    #     .synchronizers([polling])
    #
    # @see DataSystem.polling_ds_builder
    #
    class PollingDataSourceBuilder
      include LaunchDarkly::DataSystem::DataSourceBuilderCommon

      # @return [String] The default base URI for polling requests
      DEFAULT_BASE_URI = "https://sdk.launchdarkly.com"

      # @return [Float] The default polling interval in seconds
      DEFAULT_POLL_INTERVAL = 30

      def initialize
        @requester = nil
      end

      #
      # Sets the polling interval in seconds.
      #
      # This controls how frequently the SDK polls LaunchDarkly for updates.
      # Lower values mean more frequent updates but higher network traffic.
      # The default is {DEFAULT_POLL_INTERVAL} seconds.
      #
      # @param secs [Float] Polling interval in seconds
      # @return [PollingDataSourceBuilder] self for chaining
      #
      def poll_interval(secs)
        @poll_interval = secs
        self
      end

      #
      # Sets a custom {Requester} for this polling data source.
      #
      # By default, the builder uses an HTTP requester that communicates with
      # LaunchDarkly's FDv2 polling endpoint. Use this method to provide a
      # custom requester implementation for testing or non-standard environments.
      #
      # @param requester [Requester] A custom requester that implements the
      #   {Requester} interface
      # @return [PollingDataSourceBuilder] self for chaining
      #
      # @see Requester
      #
      def requester(requester)
        @requester = requester
        self
      end

      #
      # Builds the polling data source with the configured parameters.
      #
      # This method is called internally by the SDK. You do not need to call it
      # directly; instead, pass the builder to {ConfigBuilder#initializers} or
      # {ConfigBuilder#synchronizers}.
      #
      # @param sdk_key [String] The SDK key
      # @param config [LaunchDarkly::Config] The SDK configuration
      # @return [LaunchDarkly::Impl::DataSystem::PollingDataSource]
      #
      def build(sdk_key, config)
        http_opts = build_http_config
        requester = @requester || LaunchDarkly::Impl::DataSystem::HTTPPollingRequester.new(sdk_key, http_opts, config)
        LaunchDarkly::Impl::DataSystem::PollingDataSource.new(@poll_interval || DEFAULT_POLL_INTERVAL, requester, config.logger)
      end
    end

    #
    # Builder for a polling data source that communicates with LaunchDarkly's
    # FDv1 (Flag Delivery v1) polling endpoint.
    #
    # This builder is typically used with {ConfigBuilder#fdv1_compatible_synchronizer}
    # to provide a fallback when the server signals that the environment should
    # revert to the FDv1 protocol.
    #
    # Most users will not need to interact with this builder directly, as the
    # predefined strategies ({DataSystem.default}, {DataSystem.streaming},
    # {DataSystem.polling}) already configure an appropriate FDv1 fallback.
    #
    # @see DataSystem.fdv1_fallback_ds_builder
    #
    class FDv1PollingDataSourceBuilder
      include LaunchDarkly::DataSystem::DataSourceBuilderCommon

      # @return [String] The default base URI for FDv1 polling requests
      DEFAULT_BASE_URI = "https://sdk.launchdarkly.com"

      # @return [Float] The default polling interval in seconds
      DEFAULT_POLL_INTERVAL = 30

      def initialize
        @requester = nil
      end

      #
      # Sets the polling interval in seconds.
      #
      # This controls how frequently the SDK polls LaunchDarkly for updates.
      # The default is {DEFAULT_POLL_INTERVAL} seconds.
      #
      # @param secs [Float] Polling interval in seconds
      # @return [FDv1PollingDataSourceBuilder] self for chaining
      #
      def poll_interval(secs)
        @poll_interval = secs
        self
      end

      #
      # Sets a custom {Requester} for this polling data source.
      #
      # By default, the builder uses an HTTP requester that communicates with
      # LaunchDarkly's FDv1 polling endpoint. Use this method to provide a
      # custom requester implementation.
      #
      # @param requester [Requester] A custom requester that implements the
      #   {Requester} interface
      # @return [FDv1PollingDataSourceBuilder] self for chaining
      #
      # @see Requester
      #
      def requester(requester)
        @requester = requester
        self
      end

      #
      # Builds the FDv1 polling data source with the configured parameters.
      #
      # This method is called internally by the SDK. You do not need to call it
      # directly; instead, pass the builder to {ConfigBuilder#fdv1_compatible_synchronizer}.
      #
      # @param sdk_key [String] The SDK key
      # @param config [LaunchDarkly::Config] The SDK configuration
      # @return [LaunchDarkly::Impl::DataSystem::PollingDataSource]
      #
      def build(sdk_key, config)
        http_opts = build_http_config
        requester = @requester || LaunchDarkly::Impl::DataSystem::HTTPFDv1PollingRequester.new(sdk_key, http_opts, config)
        LaunchDarkly::Impl::DataSystem::PollingDataSource.new(@poll_interval || DEFAULT_POLL_INTERVAL, requester, config.logger)
      end
    end
  end
end
