
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
    # To represent the different kinds of objects that can be stored, such as feature flags and
    # segments, the SDK will provide a "kind" object; this is a hash with a single property,
    # `:namespace`, which is a short string unique to that kind. This string can be used as a
    # collection name or a key prefix.
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
      # If possible, the store should update the entire data set atomically. If that is not possible,
      # it should iterate through the outer hash and then the inner hash using the existing iteration
      # order of those hashes (the SDK will ensure that the items were inserted into the hashes in
      # the correct order), storing each item, and then delete any leftover items at the very end.
      #
      # @param all_data [Hash]  a hash where each key is one of the data kind objects, and each
      #   value is in turn a hash of string keys to entities
      # @return [void]
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
      # @return [void]
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
      # @return [void]
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
      # @return [void]
      #
      def stop
      end
    end

    #
    # Mixin that defines the required methods of a data source implementation. This is the
    # component that delivers feature flag data from LaunchDarkly to the LDClient by putting
    # the data in the {FeatureStore}. It is expected to run concurrently on its own thread.
    #
    # The client has its own standard implementation, which uses either a streaming connection or
    # polling depending on your configuration. Normally you will not need to use another one
    # except for testing purposes. {FileDataSource} provides one such test fixture.
    #
    module DataSource
      #
      # Checks whether the data source has finished initializing. Initialization is considered done
      # once it has received one complete data set from LaunchDarkly.
      #
      # @return [Boolean]  true if initialization is complete
      #
      def initialized?
      end

      #
      # Puts the data source into an active state. Normally this means it will make its first
      # connection attempt to LaunchDarkly. If `start` has already been called, calling it again
      # should simply return the same value as the first call.
      #
      # @return [Concurrent::Event]  an Event which will be set once initialization is complete
      #
      def start
      end

      #
      # Puts the data source into an inactive state and releases all of its resources.
      # This state should be considered permanent (`start` does not have to work after `stop`).
      #
      def stop
      end
    end

    #
    # Mixin that defines the required methods of an event processor implementation. This is the
    # component that receives information about analytics-generating activities from the SDK (flag
    # evaluations, and calls to `track` or `identify`) and delivers the appropriate analytics events.
    #
    # The SDK's standard implementation runs one worker thread to process the event data, and a pool
    # of up to five worker threads for delivering batches of events via HTTP to LaunchDarkly (the
    # pool will only use one thread unless the LaunchDarkly event service is running abnormally
    # slowly).
    #
    module EventProcessor
      #
      # Processes (or queues to be processed asychronously) a unit of analytics information.
      #
      # The event parameter is similar, but not identical, to the final analytics events that may be
      # delivered to LaunchDarkly (whose schema is described in the [data export documentation](https://docs.launchdarkly.com/docs/data-export-schema-reference)).
      # It will always have a `:kind` of `"feature"`, `"track"`, or `"identify"`. However:
      #
      # * The `:user` property will always contain a full user object, whereas (unless
      # `inline_users_in_events` is set in your configuration) the SDK normally deduplicates users
      # and sends only the key. The user object does not have private attributes removed.
      # * A `feature` event will have additional properties `trackEvents` and `debugEventsUntilDate`
      # which determine whether to send an individual event or just include it in a summary.
      # * It is the event processor's responsibility to add a timestamp (`creationDate`).
      #
      # The method should return as quickly as possible and must not throw any exceptions.
      #
      # @param event [Object] an event object, prior to being processed into the final schema
      #
      def add_event(event)
      end
  
      #
      # Indicates that all pending analytics events should be delivered as soon as possible.
      #
      # This implements the client's {LDClient#flush} method. It should be asynchronous and not
      # wait for event delivery to finish. It must not throw any exceptions.
      #
      def flush
      end
  
      #
      # Puts the component permanently into an inactive state and releases all of its resources.
      #
      def stop
      end
    end
  end
end
