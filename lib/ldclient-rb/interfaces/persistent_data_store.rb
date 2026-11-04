module LaunchDarkly
  module Interfaces
    #
    # The interface for a database integration that keeps feature flag data, such as Redis.
    #
    # A persistent data store keeps items in serialized form. It does not parse, cache or filter
    # them. The SDK wraps the store in {LaunchDarkly::Integrations::Util::PersistentDataStoreWrapper},
    # which serializes and deserializes the items, keeps an optional in-memory cache, and removes
    # deleted items from query results.
    #
    # Each item is a {LaunchDarkly::Interfaces::DataStore::SerializedItemDescriptor}. Each data
    # kind is a {LaunchDarkly::Interfaces::DataStore::DataKind}. The store uses the kind's
    # {LaunchDarkly::Interfaces::DataStore::DataKind#namespace} to keep the items of each kind apart.
    #
    # The store must keep deleted items. The SDK uses a deleted item to stop an older version of
    # the item from replacing the deletion.
    #
    # This module only documents the methods. It does not define them, so a store that includes
    # it keeps the methods it inherits from a superclass. A store must supply all of the methods.
    # If an operation fails, the method must raise an error. The SDK then marks the store as
    # unavailable and calls {#available?} at intervals until it returns true.
    #
    module PersistentDataStore
      #
      # @!method init(all_data)
      #   Replaces all of the data in the store.
      #
      #   If possible, the store replaces the data in one atomic operation. If that is not possible,
      #   it writes the kinds and the items in the order of the hashes, and then deletes the items
      #   that are not in the new data. The SDK puts the data in an order that keeps the store
      #   consistent during a write that is not atomic.
      #
      #   The store also records that it is initialized. See {#initialized?}.
      #
      #   @param all_data [Hash{LaunchDarkly::Interfaces::DataStore::DataKind => Hash{Symbol => LaunchDarkly::Interfaces::DataStore::SerializedItemDescriptor}}]
      #     the items of each kind, by key
      #   @return [void]
      #

      #
      # @!method get(kind, key)
      #   Gets one item.
      #
      #   A store that keeps the version apart from the serialized item returns that version. A
      #   store that does not returns a version of 0, and the SDK reads the version from the
      #   serialized item.
      #
      #   @param kind [LaunchDarkly::Interfaces::DataStore::DataKind]
      #   @param key [String, Symbol]
      #   @return [LaunchDarkly::Interfaces::DataStore::SerializedItemDescriptor, nil] the item, or
      #     nil if the store has no item with this key. A deleted item is an item.
      #

      #
      # @!method get_all(kind)
      #   Gets all of the items of one kind, including deleted items.
      #
      #   @param kind [LaunchDarkly::Interfaces::DataStore::DataKind]
      #   @return [Hash{Symbol => LaunchDarkly::Interfaces::DataStore::SerializedItemDescriptor}]
      #     the items, by key
      #

      #
      # @!method upsert(kind, key, item)
      #   Adds or replaces one item, if its version is higher than the version in the store.
      #
      #   The store does the version check and the write in one atomic operation. If the store has
      #   no item with this key, it writes the item. If the store has an item with the same or a
      #   higher version, it does not write the item. A deleted item has a version, and the same
      #   rule applies to it.
      #
      #   To get the version of a stored item that it keeps only in serialized form, the store uses
      #   {LaunchDarkly::Interfaces::DataStore::DataKind#deserialize}.
      #
      #   @param kind [LaunchDarkly::Interfaces::DataStore::DataKind]
      #   @param key [String, Symbol]
      #   @param item [LaunchDarkly::Interfaces::DataStore::SerializedItemDescriptor]
      #   @return [Boolean] true if the store wrote the item; false if the store already had an
      #     item with the same or a higher version
      #

      #
      # @!method initialized?
      #   Tells whether the store has data from an {#init}.
      #
      #   The result must be true if any process has called {#init} on a store with the same
      #   configuration, so that an SDK can use data that another SDK or the Relay Proxy wrote.
      #   The SDK caches a true result.
      #
      #   @return [Boolean]
      #

      #
      # @!method available?
      #   Tells whether the store can operate.
      #
      #   The SDK calls this method at intervals after an operation fails, until the result is true.
      #   The method can do a simple query. It must not raise an error.
      #
      #   @return [Boolean] true if the store can operate
      #

      #
      # @!method stop
      #   Releases the resources of the store. The SDK calls this method when the client closes.
      #
      #   @return [void]
      #
    end
  end
end
