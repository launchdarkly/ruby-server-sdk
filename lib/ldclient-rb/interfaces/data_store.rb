module LaunchDarkly
  module Interfaces
    module DataStore
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
