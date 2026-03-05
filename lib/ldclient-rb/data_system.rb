# frozen_string_literal: true

require 'ldclient-rb/interfaces/data_system'
require 'ldclient-rb/config'
require 'ldclient-rb/impl/data_system/polling'
require 'ldclient-rb/impl/data_system/streaming'

module LaunchDarkly
  #
  # Configuration for LaunchDarkly's data acquisition strategy.
  #
  # This module provides factory methods for creating data system configurations,
  # as well as builder classes for constructing individual data sources (polling
  # and streaming).
  #
  # == Quick Start
  #
  # For most users, the predefined strategies are sufficient:
  #
  #   # Use the default strategy (recommended)
  #   config = LaunchDarkly::Config.new(
  #     data_system: LaunchDarkly::DataSystem.default
  #   )
  #
  #   # Use streaming only
  #   config = LaunchDarkly::Config.new(
  #     data_system: LaunchDarkly::DataSystem.streaming
  #   )
  #
  #   # Use polling only
  #   config = LaunchDarkly::Config.new(
  #     data_system: LaunchDarkly::DataSystem.polling
  #   )
  #
  # == Custom Configurations
  #
  # For advanced use cases, you can build custom configurations using the
  # data source builders:
  #
  #   polling = LaunchDarkly::DataSystem.polling_ds_builder
  #     .poll_interval(60)
  #     .base_uri("https://custom-polling.example.com")
  #
  #   streaming = LaunchDarkly::DataSystem.streaming_ds_builder
  #     .initial_reconnect_delay(2)
  #     .base_uri("https://custom-streaming.example.com")
  #
  #   data_system = LaunchDarkly::DataSystem.custom
  #     .initializers([polling])
  #     .synchronizers([streaming, polling])
  #
  #   config = LaunchDarkly::Config.new(data_system: data_system)
  #
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
    Requester = LaunchDarkly::Impl::DataSystem::Requester

    #
    # Builder for the data system configuration.
    #
    # This builder configures the overall data acquisition strategy for the SDK,
    # including which data sources to use for initialization and synchronization,
    # and how to interact with a persistent data store.
    #
    # @see DataSystem.default
    # @see DataSystem.streaming
    # @see DataSystem.polling
    # @see DataSystem.custom
    #
    class ConfigBuilder
      def initialize
        @initializers = nil
        @synchronizers = nil
        @fdv1_fallback_synchronizer = nil
        @data_store_mode = LaunchDarkly::Interfaces::DataSystem::DataStoreMode::READ_ONLY
        @data_store = nil
      end

      #
      # Sets the initializers for the data system.
      #
      # Initializers are used to fetch an initial set of data when the SDK starts.
      # They are tried in order; if the first one fails, the next is tried, and so on.
      #
      # @param initializers [Array<#build(String, Config)>]
      #   Array of builders that respond to build(sdk_key, config) and return an Initializer
      # @return [ConfigBuilder] self for chaining
      #
      def initializers(initializers)
        @initializers = initializers
        self
      end

      #
      # Sets the synchronizers for the data system.
      #
      # Synchronizers keep data up-to-date after initialization. Like initializers,
      # they are tried in order. If the primary synchronizer fails, the next one
      # takes over.
      #
      # @param synchronizers [Array<#build(String, Config)>]
      #   Array of builders that respond to build(sdk_key, config) and return a Synchronizer
      # @return [ConfigBuilder] self for chaining
      #
      def synchronizers(synchronizers)
        @synchronizers = synchronizers
        self
      end

      #
      # Configures the SDK with a fallback synchronizer that is compatible with
      # the Flag Delivery v1 API.
      #
      # This fallback is used when the server signals that the environment should
      # revert to FDv1 protocol. Most users will not need to set this directly.
      #
      # @param fallback [#build(String, Config)] Builder that responds to build(sdk_key, config) and returns the fallback Synchronizer
      # @return [ConfigBuilder] self for chaining
      #
      def fdv1_compatible_synchronizer(fallback)
        @fdv1_fallback_synchronizer = fallback
        self
      end

      #
      # Sets the data store configuration for the data system.
      #
      # @param data_store [LaunchDarkly::Interfaces::FeatureStore] The data store
      # @param store_mode [Symbol] The store mode (use constants from
      #   {LaunchDarkly::Interfaces::DataSystem::DataStoreMode})
      # @return [ConfigBuilder] self for chaining
      #
      def data_store(data_store, store_mode)
        @data_store = data_store
        @data_store_mode = store_mode
        self
      end

      #
      # Builds the data system configuration.
      #
      # @return [DataSystemConfig]
      #
      def build
        DataSystemConfig.new(
          initializers: @initializers,
          synchronizers: @synchronizers,
          data_store_mode: @data_store_mode,
          data_store: @data_store,
          fdv1_fallback_synchronizer: @fdv1_fallback_synchronizer
        )
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
      DEFAULT_BASE_URI = LaunchDarkly::Impl::DataSystem::DEFAULT_POLLING_BASE_URI

      # @return [Float] The default polling interval in seconds
      DEFAULT_POLL_INTERVAL = LaunchDarkly::Impl::DataSystem::DEFAULT_POLL_INTERVAL

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
      DEFAULT_BASE_URI = LaunchDarkly::Impl::DataSystem::DEFAULT_POLLING_BASE_URI

      # @return [Float] The default polling interval in seconds
      DEFAULT_POLL_INTERVAL = LaunchDarkly::Impl::DataSystem::DEFAULT_POLL_INTERVAL

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

    #
    # Builder for a streaming data source that uses Server-Sent Events (SSE)
    # to receive real-time updates from LaunchDarkly's Flag Delivery services.
    #
    # This builder can be used with {ConfigBuilder#synchronizers} to create
    # custom data system configurations. Streaming provides the lowest latency
    # for flag updates compared to polling.
    #
    # == Example
    #
    #   streaming = LaunchDarkly::DataSystem.streaming_ds_builder
    #     .initial_reconnect_delay(2)
    #     .base_uri("https://custom-stream.example.com")
    #
    #   data_system = LaunchDarkly::DataSystem.custom
    #     .synchronizers([streaming])
    #
    # @see DataSystem.streaming_ds_builder
    #
    class StreamingDataSourceBuilder
      include LaunchDarkly::DataSystem::DataSourceBuilderCommon

      # @return [String] The default base URI for streaming connections
      DEFAULT_BASE_URI = LaunchDarkly::Impl::DataSystem::DEFAULT_STREAMING_BASE_URI

      # @return [Float] The default initial reconnect delay in seconds
      DEFAULT_INITIAL_RECONNECT_DELAY = LaunchDarkly::Impl::DataSystem::DEFAULT_INITIAL_RECONNECT_DELAY

      def initialize
        # No initialization needed - defaults applied in build via nil-check
      end

      #
      # Sets the initial delay before reconnecting after a stream connection error.
      #
      # The SDK uses an exponential backoff strategy starting from this delay.
      # The default is {DEFAULT_INITIAL_RECONNECT_DELAY} second.
      #
      # @param delay [Float] Delay in seconds
      # @return [StreamingDataSourceBuilder] self for chaining
      #
      def initial_reconnect_delay(delay)
        @initial_reconnect_delay = delay
        self
      end

      #
      # Builds the streaming data source with the configured parameters.
      #
      # This method is called internally by the SDK. You do not need to call it
      # directly; instead, pass the builder to {ConfigBuilder#synchronizers}.
      #
      # @param sdk_key [String] The SDK key
      # @param config [LaunchDarkly::Config] The SDK configuration
      # @return [LaunchDarkly::Impl::DataSystem::StreamingDataSource]
      #
      def build(sdk_key, config)
        http_opts = build_http_config
        LaunchDarkly::Impl::DataSystem::StreamingDataSource.new(
          sdk_key, http_opts,
          @initial_reconnect_delay || DEFAULT_INITIAL_RECONNECT_DELAY,
          config
        )
      end
    end

    #
    # Returns a builder for creating a polling data source.
    # This is a building block that can be used with {ConfigBuilder#initializers}
    # or {ConfigBuilder#synchronizers} to create custom data system configurations.
    #
    # @return [PollingDataSourceBuilder]
    #
    def self.polling_ds_builder
      PollingDataSourceBuilder.new
    end

    #
    # Returns a builder for creating an FDv1 fallback polling data source.
    # This is a building block that can be used with {ConfigBuilder#fdv1_compatible_synchronizer}
    # to provide FDv1 compatibility in custom data system configurations.
    #
    # @return [FDv1PollingDataSourceBuilder]
    #
    def self.fdv1_fallback_ds_builder
      FDv1PollingDataSourceBuilder.new
    end

    #
    # Returns a builder for creating a streaming data source.
    # This is a building block that can be used with {ConfigBuilder#synchronizers}
    # to create custom data system configurations.
    #
    # @return [StreamingDataSourceBuilder]
    #
    def self.streaming_ds_builder
      StreamingDataSourceBuilder.new
    end

    #
    # Default is LaunchDarkly's recommended flag data acquisition strategy.
    #
    # Currently, it operates a two-phase method for obtaining data: first, it
    # requests data from LaunchDarkly's global CDN. Then, it initiates a
    # streaming connection to LaunchDarkly's Flag Delivery services to
    # receive real-time updates.
    #
    # If the streaming connection is interrupted for an extended period of
    # time, the SDK will automatically fall back to polling the global CDN
    # for updates.
    #
    # @return [ConfigBuilder]
    #
    def self.default
      polling_builder = polling_ds_builder
      streaming_builder = streaming_ds_builder
      fallback = fdv1_fallback_ds_builder

      builder = ConfigBuilder.new
      builder.initializers([polling_builder])
      builder.synchronizers([streaming_builder, polling_builder])
      builder.fdv1_compatible_synchronizer(fallback)

      builder
    end

    #
    # Streaming configures the SDK to efficiently stream flag/segment data
    # in the background, allowing evaluations to operate on the latest data
    # with no additional latency.
    #
    # @return [ConfigBuilder]
    #
    def self.streaming
      streaming_builder = streaming_ds_builder
      fallback = fdv1_fallback_ds_builder

      builder = ConfigBuilder.new
      builder.synchronizers([streaming_builder])
      builder.fdv1_compatible_synchronizer(fallback)

      builder
    end

    #
    # Polling configures the SDK to regularly poll an endpoint for
    # flag/segment data in the background. This is less efficient than
    # streaming, but may be necessary in some network environments.
    #
    # @return [ConfigBuilder]
    #
    def self.polling
      polling_builder = polling_ds_builder
      fallback = fdv1_fallback_ds_builder

      builder = ConfigBuilder.new
      builder.synchronizers([polling_builder])
      builder.fdv1_compatible_synchronizer(fallback)

      builder
    end

    #
    # Custom returns a builder suitable for creating a custom data
    # acquisition strategy. You may configure how the SDK uses a Persistent
    # Store, how the SDK obtains an initial set of data, and how the SDK
    # keeps data up-to-date.
    #
    # @return [ConfigBuilder]
    #
    def self.custom
      ConfigBuilder.new
    end

    #
    # Daemon configures the SDK to read from a persistent store integration
    # that is populated by Relay Proxy or other SDKs. The SDK will not connect
    # to LaunchDarkly. In this mode, the SDK never writes to the data store.
    #
    # @param store [Object] The persistent store
    # @return [ConfigBuilder]
    #
    def self.daemon(store)
      custom.data_store(store, LaunchDarkly::Interfaces::DataSystem::DataStoreMode::READ_ONLY)
    end

    #
    # PersistentStore is similar to default, with the addition of a persistent
    # store integration. Before data has arrived from LaunchDarkly, the SDK is
    # able to evaluate flags using data from the persistent store. Once fresh
    # data is available, the SDK will no longer read from the persistent store,
    # although it will keep it up-to-date.
    #
    # @param store [Object] The persistent store
    # @return [ConfigBuilder]
    #
    def self.persistent_store(store)
      default.data_store(store, LaunchDarkly::Interfaces::DataSystem::DataStoreMode::READ_WRITE)
    end
  end
end
