# frozen_string_literal: true

require "ldclient-rb/interfaces/data_system"

module LaunchDarkly
  module DataSystem
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
        @overrides = nil
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
      # Configures the SDK with an override source. Flag overrides are currently experimental and
      # subject to change.
      #
      # Overrides are flag and segment definitions that take precedence over data received from
      # LaunchDarkly at evaluation time, on a per-key basis. They exist for resilience during an
      # incident. Overrides let an operator force one or more flags to a known state on a running
      # client, whether or not the client can reach LaunchDarkly. Flags not present in the override
      # data are completely unaffected.
      #
      # The override source is not a data source. It has no effect on the client's initialization
      # status, data availability, or data source status. Without a configured source, or while
      # the source supplies no overrides, the SDK behaves as it would without this feature.
      #
      # At most one override source can be configured. A later call replaces an earlier one.
      #
      # @example
      #   overrides = LaunchDarkly::Integrations::FileData.override_source(paths: ["/etc/launchdarkly/overrides.json"])
      #   config = LaunchDarkly::Config.new(data_system: LaunchDarkly::DataSystem.default.overrides(overrides))
      #
      # @param source [#build(String, Config), nil] a builder that responds to build(sdk_key, config)
      #   and returns a {LaunchDarkly::Interfaces::Overrides::OverrideSource}, or nil to remove one
      # @return [ConfigBuilder] self for chaining
      #
      def overrides(source)
        @overrides = source
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
          fdv1_fallback_synchronizer: @fdv1_fallback_synchronizer,
          overrides: @overrides
        )
      end
    end
  end
end
