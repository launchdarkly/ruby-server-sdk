# frozen_string_literal: true

require 'ldclient-rb/interfaces/data_system'
require 'ldclient-rb/config'
require 'ldclient-rb/impl/data_system/polling'
require 'ldclient-rb/impl/data_system/streaming'
require 'ldclient-rb/data_system/config_builder'
require 'ldclient-rb/data_system/polling_data_source_builder'
require 'ldclient-rb/data_system/streaming_data_source_builder'

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
