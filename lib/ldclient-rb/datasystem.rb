# frozen_string_literal: true

require 'ldclient-rb/interfaces/data_system'
require 'ldclient-rb/config'

module LaunchDarkly
  #
  # Configuration for LaunchDarkly's data acquisition strategy.
  #
  # This module provides factory methods for creating data system configurations.
  #
  module DataSystem
    #
    # Builder for the data system configuration.
    #
    class ConfigBuilder
      def initialize
        @initializers = nil
        @primary_synchronizer = nil
        @secondary_synchronizer = nil
        @fdv1_fallback_synchronizer = nil
        @data_store_mode = LaunchDarkly::Interfaces::DataStoreMode::READ_ONLY
        @data_store = nil
      end

      #
      # Sets the initializers for the data system.
      #
      # @param initializers [Array<Proc(String, Config) => LaunchDarkly::Interfaces::DataSystem::Initializer>]
      #   Array of builder procs that take sdk_key and Config and return an Initializer
      # @return [ConfigBuilder] self for chaining
      #
      def initializers(initializers)
        @initializers = initializers
        self
      end

      #
      # Sets the synchronizers for the data system.
      #
      # @param primary [Proc(String, Config) => LaunchDarkly::Interfaces::DataSystem::Synchronizer] Builder proc that takes sdk_key and Config and returns the primary Synchronizer
      # @param secondary [Proc(String, Config) => LaunchDarkly::Interfaces::DataSystem::Synchronizer, nil]
      #   Builder proc that takes sdk_key and Config and returns the secondary Synchronizer
      # @return [ConfigBuilder] self for chaining
      #
      def synchronizers(primary, secondary = nil)
        @primary_synchronizer = primary
        @secondary_synchronizer = secondary
        self
      end

      #
      # Configures the SDK with a fallback synchronizer that is compatible with
      # the Flag Delivery v1 API.
      #
      # @param fallback [Proc(String, Config) => LaunchDarkly::Interfaces::DataSystem::Synchronizer]
      #   Builder proc that takes sdk_key and Config and returns the fallback Synchronizer
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
      # @param store_mode [Symbol] The store mode
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
      # @raise [ArgumentError] if configuration is invalid
      #
      def build
        if @secondary_synchronizer && @primary_synchronizer.nil?
          raise ArgumentError, "Primary synchronizer must be set if secondary is set"
        end

        DataSystemConfig.new(
          initializers: @initializers,
          primary_synchronizer: @primary_synchronizer,
          secondary_synchronizer: @secondary_synchronizer,
          data_store_mode: @data_store_mode,
          data_store: @data_store,
          fdv1_fallback_synchronizer: @fdv1_fallback_synchronizer
        )
      end
    end

    # @private
    def self.polling_ds_builder
      # TODO(fdv2): Implement polling data source builder
      lambda do |_sdk_key, _config|
        raise NotImplementedError, "Polling data source not yet implemented for FDv2"
      end
    end

    # @private
    def self.fdv1_fallback_ds_builder
      # TODO(fdv2): Implement FDv1 fallback polling data source builder
      lambda do |_sdk_key, _config|
        raise NotImplementedError, "FDv1 fallback data source not yet implemented for FDv2"
      end
    end

    # @private
    def self.streaming_ds_builder
      # TODO(fdv2): Implement streaming data source builder
      lambda do |_sdk_key, _config|
        raise NotImplementedError, "Streaming data source not yet implemented for FDv2"
      end
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
      builder.synchronizers(streaming_builder, polling_builder)
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
      builder.synchronizers(streaming_builder)
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
      builder.synchronizers(polling_builder)
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
      default.data_store(store, LaunchDarkly::Interfaces::DataStoreMode::READ_ONLY)
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
      default.data_store(store, LaunchDarkly::Interfaces::DataStoreMode::READ_WRITE)
    end
  end
end

