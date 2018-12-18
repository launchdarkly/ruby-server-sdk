
module LaunchDarkly
  #
  # Mixins that define the required methods of various pluggable components used by the client.
  #
  module Interfaces
    #
    # Mixin that defines the required methods of a feature store implementation. The LaunchDarkly
    # client uses the feature store to persist feature flags and related objects received from
    # the LaunchDarkly service. Implementations must support concurrent access and updates.
    # For more about how feature stores can be used, see:
    # [Using a persistent feature store](https://docs.launchdarkly.com/v2.0/docs/using-a-persistent-feature-store).
    #
    # An entity that can be stored in a feature store is a hash that can be converted to and from
    # JSON, and that has at a minimum the following properties: `:key`, a string that is unique
    # among entities of the same kind; `:version`, an integer that is higher for newer data;
    # `:deleted`, a boolean (optional, defaults to false) that if true means this is a
    # placeholder for a deleted entity.
    #
    # Examples of a "kind" are feature flags and segments; each of these is associated with an
    # object such as {LaunchDarkly::FEATURES} and {LaunchDarkly::SEGMENTS}. The "kind" objects are
    # hashes with a single property, `:namespace`, which is a short string unique to that kind.
    #
    # The default implementation is {LaunchDarkly::InMemoryFeatureStore}. Several implementations
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
      # @param all_data [Hash]  a hash where each key is one of the data kind objects, and each
      #   value is in turn a hash of string keys to entities
      #
      def init(all_data)
      end

      #
      # Returns the entity to which the specified key is mapped, if any.
      #
      # @param kind [Object]  the kind of entity to get
      # @param key [String]  the unique key of the entity to get
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
      # @param kind [Object]  the kind of entity to add or update
      # @param item [Hash]  the entity to add or update
      #
      def upsert(kind, item)
      end

      #
      # Attempt to delete an entity if it exists. Deletion should only succeed if the
      # `version` parameter is greater than the existing entity's `:version`; otherwise, the
      # method should do nothing.
      #
      # @param kind [Object]  the kind of entity to delete
      # @param key [String]  the unique key of the entity
      # @param version [Integer]  the entity must have a lower version than this to be deleted
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
      def stop
      end
    end
  end
end
