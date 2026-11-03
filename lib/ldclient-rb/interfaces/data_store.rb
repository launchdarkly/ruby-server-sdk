module LaunchDarkly
  module Interfaces
    module DataStore
      #
      # A kind of data that the SDK keeps in a data store, such as feature flags or segments.
      #
      # The SDK gives a data kind to each data store operation. A persistent data store uses
      # {#namespace} to keep the items of each kind apart. It can use {#deserialize} to get the
      # version of an item that it has in serialized form.
      #
      # The SDK supplies the data kinds {FEATURES} and {SEGMENTS}. Application code does not
      # usually create a data kind.
      #
      class DataKind
        FEATURE_PREREQ_FN = lambda { |flag| (flag[:prerequisites] || []).map { |p| p[:key] } }.freeze
        private_constant :FEATURE_PREREQ_FN

        #
        # The name of the kind, for example "features". A data store uses this name to keep the
        # items of each kind apart.
        #
        # @return [String]
        #
        attr_reader :namespace

        #
        # The order in which the SDK writes this kind to a data store. The SDK writes a kind with
        # a lower priority first.
        #
        # @return [Integer]
        #
        attr_reader :priority

        #
        # @param namespace [String]
        # @param priority [Integer]
        #
        def initialize(namespace:, priority:)
          @namespace = namespace
          @priority = priority
        end

        #
        # Converts an item of this kind to a string for a data store.
        #
        # A deleted item becomes a placeholder that has the item's key and version and the
        # property "deleted" with the value true.
        #
        # @param item [Object] an item of this kind, or a deleted item placeholder
        # @return [String]
        #
        def serialize(item)
          LaunchDarkly::Impl::Model.serialize(self, item)
        end

        #
        # Converts a string from a data store to an item of this kind.
        #
        # @param serialized [String] the string that {#serialize} made
        # @param logger [Logger, nil] logs data validation problems, if any
        # @return [Object] the item, or a deleted item placeholder
        #
        def deserialize(serialized, logger = nil)
          LaunchDarkly::Impl::Model.deserialize(self, serialized, logger)
        end

        #
        # Gives the properties of this kind by name, as when data kinds were hashes.
        #
        # @param key [Symbol]
        # @return [Object]
        #
        def [](key)
          return priority if key == :priority
          return namespace if key == :namespace
          return get_dependency_keys_fn() if key == :get_dependency_keys
          nil
        end

        #
        # Gives a function that returns the keys of the items an item depends on. Only feature
        # flags have dependencies.
        #
        # @return [Proc, nil]
        #
        def get_dependency_keys_fn()
          return nil unless @namespace == FEATURES.namespace

          FEATURE_PREREQ_FN
        end

        def eql?(other)
          other.is_a?(DataKind) && namespace == other.namespace && priority == other.priority
        end

        def hash
          [namespace, priority].hash
        end
      end

      #
      # The data kind for feature flags.
      #
      FEATURES = DataKind.new(namespace: "features", priority: 1).freeze

      #
      # The data kind for segments. The SDK writes segments before feature flags, because
      # feature flags can refer to segments.
      #
      SEGMENTS = DataKind.new(namespace: "segments", priority: 0).freeze

      #
      # All of the data kinds that the SDK keeps in a data store.
      #
      ALL_KINDS = [FEATURES, SEGMENTS].freeze

      #
      # An item in the serialized form that a persistent data store keeps.
      #
      # The SDK serializes items before it gives them to a persistent data store, and
      # deserializes the items that the store returns. The store keeps only the serialized string
      # and the version.
      #
      # @!attribute [r] version
      #   @return [Integer] the version of the item. A store that does not keep the version
      #     separately returns 0, and the SDK gets the version from the serialized item.
      # @!attribute [r] deleted
      #   @return [Boolean] true if the item is a deleted item placeholder
      # @!attribute [r] serialized_item
      #   @return [String, nil] the serialized item, from {DataKind#serialize}
      #
      SerializedItemDescriptor = Data.define(:version, :deleted, :serialized_item)

      #
      # An interface for querying the status of a persistent data store.
      #
      # An implementation of this interface is returned by {LaunchDarkly::LDClient#data_store_status_provider}.
      # Application code should not implement this interface.
      #
      module StatusProvider
        #
        # Returns the current status of the store.
        #
        # This is only meaningful for persistent stores, or any custom data store implementation that makes use of
        # the status reporting mechanism provided by the SDK. For the default in-memory store, the status will always
        # be reported as "available".
        #
        # @return [Status] the latest status
        #
        def status
        end

        #
        # Indicates whether the current data store implementation supports status monitoring.
        #
        # This is normally true for all persistent data stores, and false for the default in-memory store. A true value
        # means that any listeners added with {#add_listener} can expect to be notified if there is any error in
        # storing data, and then notified again when the error condition is resolved. A false value means that the
        # status is not meaningful and listeners should not expect to be notified.
        #
        # @return [Boolean] true if status monitoring is enabled
        #
        def monitoring_enabled?
        end

        #
        # Subscribes for notifications of status changes.
        #
        # Applications may wish to know if there is an outage in a persistent data store, since that could mean that
        # flag evaluations are unable to get the flag data from the store (unless it is currently cached) and therefore
        # might return default values.
        #
        # If the SDK receives an exception while trying to query or update the data store, then it notifies listeners
        # that the store appears to be offline ({Status#available} is false) and begins polling the store
        # at intervals until a query succeeds. Once it succeeds, it notifies listeners again with {Status#available}
        # set to true.
        #
        # This method has no effect if the data store implementation does not support status tracking, such as if you
        # are using the default in-memory store rather than a persistent store.
        #
        # @param listener [#update] the listener to add
        #
        def add_listener(listener)
        end

        #
        # Unsubscribes from notifications of status changes.
        #
        # This method has no effect if the data store implementation does not support status tracking, such as if you
        # are using the default in-memory store rather than a persistent store.
        #
        # @param listener [Object] the listener to remove; if no such listener was added, this does nothing
        #
        def remove_listener(listener)
        end
      end

      #
      # Interface that a data store implementation can use to report information back to the SDK.
      #
      module UpdateSink
        #
        # Reports a change in the data store's operational status.
        #
        # This is what makes the status monitoring mechanisms in {StatusProvider} work.
        #
        # @param status [Status] the updated status properties
        #
        def update_status(status)
        end
      end

      class Status
        def initialize(available, stale)
          @available = available
          @stale = stale
        end

        #
        # Returns true if the SDK believes the data store is now available.
        #
        # This property is normally true. If the SDK receives an exception while trying to query or update the data
        # store, then it sets this property to false (notifying listeners, if any) and polls the store at intervals
        # until a query succeeds. Once it succeeds, it sets the property back to true (again notifying listeners).
        #
        # @return [Boolean] true if store is available
        #
        attr_reader :available

        #
        # Returns true if the store may be out of date due to a previous
        # outage, so the SDK should attempt to refresh all feature flag data
        # and rewrite it to the store.
        #
        # This property is not meaningful to application code.
        #
        # @return [Boolean] true if data should be rewritten
        #
        attr_reader :stale
      end
    end
  end
end
