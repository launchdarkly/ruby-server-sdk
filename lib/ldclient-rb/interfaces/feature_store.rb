module LaunchDarkly
  module Interfaces
    #
    # Mixin that defines the required methods of a feature store implementation. The LaunchDarkly
    # client uses the feature store to persist feature flags and related objects received from
    # the LaunchDarkly service. Implementations must support concurrent access and updates.
    # For more about how feature stores can be used, see:
    # [Using a persistent feature store](https://docs.launchdarkly.com/sdk/features/storing-data#ruby).
    #
    # An entity that can be stored in a feature store is a hash that can be converted to and from
    # JSON, and that has at a minimum the following properties: `:key`, a string that is unique
    # among entities of the same kind; `:version`, an integer that is higher for newer data;
    # `:deleted`, a boolean (optional, defaults to false) that if true means this is a
    # placeholder for a deleted entity.
    #
    # To represent the different kinds of objects that can be stored, such as feature flags and
    # segments, the SDK will provide a "kind" object; this is a hash with a single property,
    # `:namespace`, which is a short string unique to that kind. This string can be used as a
    # collection name or a key prefix.
    #
    # A persistent store implements this interface. Give it to {LaunchDarkly::DataSystem.persistent_store}
    # or {LaunchDarkly::DataSystem.daemon}. Several implementations
    # that use databases can be found in {LaunchDarkly::Integrations}. If you want to write a new
    # implementation, see {LaunchDarkly::Integrations::Util} for tools that can make this task
    # simpler.
    #
    module FeatureStore
      #
      # Initializes (or re-initializes) the store with the specified set of entities. Any
      # existing entries will be removed. Implementations can assume that this data set is up to
      # date-- there is no need to perform individual version comparisons between the existing
      # objects and the supplied features.
      #
      # If possible, the store should update the entire data set atomically. If that is not possible,
      # it should iterate through the outer hash and then the inner hash using the existing iteration
      # order of those hashes (the SDK will ensure that the items were inserted into the hashes in
      # the correct order), storing each item, and then delete any leftover items at the very end.
      #
      # @param all_data [Hash]  a hash where each key is one of the data kind objects, and each
      #   value is in turn a hash of symbol keys to entities
      # @return [void]
      #
      def init(all_data)
      end

      #
      # Returns the entity to which the specified key is mapped, if any.
      #
      # @param kind [Object]  the kind of entity to get
      # @param key [String, Symbol]  the unique key of the entity to get
      # @return [Hash]  the entity; nil if the key was not found, or if the stored entity's
      #   `:deleted` property was true
      #
      def get(kind, key)
      end

      #
      # Returns all stored entities of the specified kind, not including deleted entities.
      #
      # @param kind [Object]  the kind of entity to get
      # @return [Hash]  a hash where each key is the entity's `:key` property and each value
      #   is the entity
      #
      def all(kind)
      end

      #
      # Attempt to add an entity, or update an existing entity with the same key. An update
      # should only succeed if the new item's `:version` is greater than the old one;
      # otherwise, the method should do nothing.
      #
      # The SDK uses the return value to decide whether to send flag change events.
      #
      # @param kind [Object]  the kind of entity to add or update
      # @param item [Hash]  the entity to add or update
      # @return [Boolean]  true if the store applied the update; false if the store already
      #   had an item with the same or a higher version
      #
      def upsert(kind, item)
      end

      #
      # Attempt to delete an entity if it exists. Deletion should only succeed if the
      # `version` parameter is greater than the existing entity's `:version`; otherwise, the
      # method should do nothing.
      #
      # The SDK uses the return value to decide whether to send flag change events.
      #
      # @param kind [Object]  the kind of entity to delete
      # @param key [String]  the unique key of the entity
      # @param version [Integer]  the entity must have a lower version than this to be deleted
      # @return [Boolean]  true if the store applied the deletion; false if the store already
      #   had an item with the same or a higher version
      #
      def delete(kind, key, version)
      end

      #
      # Checks whether this store has been initialized. That means that `init` has been called
      # either by this process, or (if the store can be shared) by another process. This
      # method will be called frequently, so it should be efficient. You can assume that if it
      # has returned true once, it can continue to return true, i.e. a store cannot become
      # uninitialized again.
      #
      # @return [Boolean]  true if the store is in an initialized state
      #
      def initialized?
      end

      #
      # Performs any necessary cleanup to shut down the store when the client is being shut down.
      #
      # This method should be idempotent - it is safe to call it multiple times, and subsequent
      # calls after the first should have no effect.
      #
      # @return [void]
      #
      def stop
      end

      #
      # Returns true if this store supports status monitoring.
      #
      # This is normally true only for persistent data stores. A custom
      # {FeatureStore} implementation can also return true.
      #
      # If this method returns true, the store must publish a status update
      # when it enters an invalid state. An invalid state is a state where an
      # operation has failed, or where the store knows that operations cannot
      # succeed. The store must then publish another status update when it
      # returns to a valid state. The SDK uses {#available?} to detect this
      # return.
      #
      # In-memory stores must return false.
      #
      # The SDK returns the same value from
      # {LaunchDarkly::Interfaces::DataStore::StatusProvider#monitoring_enabled?}.
      #
      # @return [Boolean] true if the store supports status monitoring
      #
      def monitoring_enabled?
      end

      #
      # Tests whether the data store operates normally.
      #
      # This must not be a detailed test of different kinds of operations. Do
      # the smallest possible operation that shows that the store works. For
      # example, make sure that the database is reachable.
      #
      # When one of the other methods of the store raises an exception, the SDK
      # assumes that the store can be unavailable. If {#monitoring_enabled?}
      # returns true, the SDK then calls this method at intervals until it
      # returns true.
      #
      # Stores that cannot become unavailable, such as in-memory stores, must
      # return true.
      #
      # @return [Boolean] true if the underlying data store is reachable
      #
      def available?
      end
    end
  end
end
