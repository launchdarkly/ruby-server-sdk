require "observer"

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

      #
      # WARN: This isn't a required method on a FeatureStore yet. The SDK will
      # currently check if the provided store responds to this method, and if
      # it does, will take appropriate action based on the documented behavior
      # below. This will become required in a future major version release of
      # the SDK.
      #
      # Returns true if this data store implementation supports status
      # monitoring.
      #
      # This is normally only true for persistent data stores but it could also
      # be true for any custom {FeatureStore} implementation.
      #
      # Returning true means that the store guarantees that if it ever enters
      # an invalid state (that is, an operation has failed or it knows that
      # operations cannot succeed at the moment), it will publish a status
      # update, and will then publish another status update once it has
      # returned to a valid state.
      #
      # Custom implementations must implement `def available?` which
      # synchronously checks if the store is available. Without this method,
      # the SDK cannot ensure status updates will occur once the store has gone
      # offline.
      #
      # The same value will be returned from
      # {StatusProvider::monitoring_enabled?}.
      #
      # def monitoring_enabled? end

      #
      # WARN: This isn't a required method on a FeatureStore. The SDK will
      # check if the provided store responds to this method, and if it does,
      # will take appropriate action based on the documented behavior below.
      # Usage of this method will be dropped in a future version of the SDK.
      #
      # Tests whether the data store seems to be functioning normally.
      #
      # This should not be a detailed test of different kinds of operations,
      # but just the smallest possible operation to determine whether (for
      # instance) we can reach the database.
      #
      # Whenever one of the store's other methods throws an exception, the SDK
      # will assume that it may have become unavailable (e.g. the database
      # connection was lost). The SDK will then call {#available?} at intervals
      # until it returns true.
      #
      # @return [Boolean] true if the underlying data store is reachable
      #
      # def available? end
    end

    #
    # An interface for tracking changes in feature flag configurations.
    #
    # An implementation of this interface is returned by {LaunchDarkly::LDClient#flag_tracker}.
    # Application code never needs to implement this interface.
    #
    module FlagTracker
      #
      # Registers a listener to be notified of feature flag changes in general.
      #
      # The listener will be notified whenever the SDK receives any change to any feature flag's configuration,
      # or to a user segment that is referenced by a feature flag. If the updated flag is used as a prerequisite
      # for other flags, the SDK assumes that those flags may now behave differently and sends flag change events
      # for them as well.
      #
      # Note that this does not necessarily mean the flag's value has changed for any particular evaluation
      # context, only that some part of the flag configuration was changed so that it may return a
      # different value than it previously returned for some context. If you want to track flag value changes,
      # use {#add_flag_value_change_listener} instead.
      #
      # It is possible, given current design restrictions, that a listener might be notified when no change has
      # occurred. This edge case will be addressed in a later version of the SDK. It is important to note this issue
      # does not affect {#add_flag_value_change_listener} listeners.
      #
      # If using the file data source, any change in a data file will be treated as a change to every flag. Again,
      # use {#add_flag_value_change_listener} (or just re-evaluate the flag # yourself) if you want to know whether
      # this is a change that really affects a flag's value.
      #
      # Change events only work if the SDK is actually connecting to LaunchDarkly (or using the file data source).
      # If the SDK is only reading flags from a database then it cannot know when there is a change, because
      # flags are read on an as-needed basis.
      #
      # The listener will be called from a worker thread.
      #
      # Calling this method for an already-registered listener has no effect.
      #
      # @param listener [#update]
      #
      def add_listener(listener) end

      #
      # Unregisters a listener so that it will no longer be notified of feature flag changes.
      #
      # Calling this method for a listener that was not previously registered has no effect.
      #
      # @param listener [Object]
      #
      def remove_listener(listener) end

      #
      # Registers a listener to be notified of a change in a specific feature flag's value for a specific
      # evaluation context.
      #
      # When you call this method, it first immediately evaluates the feature flag. It then uses
      # {#add_listener} to start listening for feature flag configuration
      # changes, and whenever the specified feature flag changes, it re-evaluates the flag for the same context.
      # It then calls your listener if and only if the resulting value has changed.
      #
      # All feature flag evaluations require an instance of {LaunchDarkly::LDContext}. If the feature flag you are
      # tracking does not have any context targeting rules, you must still pass a dummy context such as
      # `LDContext.with_key("for-global-flags")`. If you do not want the user to appear on your dashboard,
      # use the anonymous property: `LDContext.create({key: "for-global-flags", kind: "user", anonymous: true})`.
      #
      # The returned listener represents the subscription that was created by this method
      # call; to unsubscribe, pass that object (not your listener) to {#remove_listener}.
      #
      # @param key [Symbol]
      # @param context [LaunchDarkly::LDContext]
      # @param listener [#update]
      #
      def add_flag_value_change_listener(key, context, listener) end
    end

    #
    # Change event fired when some aspect of the flag referenced by the key has changed.
    #
    class FlagChange
      attr_accessor :key

      # @param [Symbol] key
      def initialize(key)
        @key = key
      end
    end

    #
    # Change event fired when the evaluated value for the specified flag key has changed.
    #
    class FlagValueChange
      attr_accessor :key
      attr_accessor :old_value
      attr_accessor :new_value

      # @param [Symbol] key
      # @param [Object] old_value
      # @param [Object] new_value
      def initialize(key, old_value, new_value)
        @key = key
        @old_value = old_value
        @new_value = new_value
      end
    end

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

    #
    # Mixin that defines the required methods of a data source implementation. This is the
    # component that delivers feature flag data from LaunchDarkly to the LDClient by putting
    # the data in the {FeatureStore}. It is expected to run concurrently on its own thread.
    #
    # The client has its own standard implementation, which uses either a streaming connection or
    # polling depending on your configuration. Normally you will not need to use another one
    # except for testing purposes. Two such test fixtures are {LaunchDarkly::Integrations::FileData}
    # and {LaunchDarkly::Integrations::TestData}.
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

    module BigSegmentStore
      #
      # Returns information about the overall state of the store. This method will be called only
      # when the SDK needs the latest state, so it should not be cached.
      #
      # @return [BigSegmentStoreMetadata]
      #
      def get_metadata
      end

      #
      # Queries the store for a snapshot of the current segment state for a specific context.
      #
      # The context_hash is a base64-encoded string produced by hashing the context key as defined by
      # the Big Segments specification; the store implementation does not need to know the details
      # of how this is done, because it deals only with already-hashed keys, but the string can be
      # assumed to only contain characters that are valid in base64.
      #
      # The return value should be either a Hash, or nil if the context is not referenced in any big
      # segments. Each key in the Hash is a "segment reference", which is how segments are
      # identified in Big Segment data. This string is not identical to the segment key-- the SDK
      # will add other information. The store implementation should not be concerned with the
      # format of the string. Each value in the Hash is true if the context is explicitly included in
      # the segment, false if the context is explicitly excluded from the segment-- and is not also
      # explicitly included (that is, if both an include and an exclude existed in the data, the
      # include would take precedence). If the context's status in a particular segment is undefined,
      # there should be no key or value for that segment.
      #
      # This Hash may be cached by the SDK, so it should not be modified after it is created. It
      # is a snapshot of the segment membership state at one point in time.
      #
      # @param context_hash [String]
      # @return [Hash] true/false values for Big Segments that reference this context
      #
      def get_membership(context_hash)
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
    # Values returned by {BigSegmentStore#get_metadata}.
    #
    class BigSegmentStoreMetadata
      def initialize(last_up_to_date)
        @last_up_to_date = last_up_to_date
      end

      # The Unix epoch millisecond timestamp of the last update to the {BigSegmentStore}. It is
      # nil if the store has never been updated.
      #
      # @return [Integer|nil]
      attr_reader :last_up_to_date
    end

    #
    # Information about the status of a Big Segment store, provided by {BigSegmentStoreStatusProvider}.
    #
    # Big Segments are a specific type of segments. For more information, read the LaunchDarkly
    # documentation: https://docs.launchdarkly.com/home/users/big-segments
    #
    class BigSegmentStoreStatus
      def initialize(available, stale)
        @available = available
        @stale = stale
      end

      # True if the Big Segment store is able to respond to queries, so that the SDK can evaluate
      # whether a context is in a segment or not.
      #
      # If this property is false, the store is not able to make queries (for instance, it may not have
      # a valid database connection). In this case, the SDK will treat any reference to a Big Segment
      # as if no contexts are included in that segment. Also, the {EvaluationReason} associated with
      # with any flag evaluation that references a Big Segment when the store is not available will
      # have a `big_segments_status` of `STORE_ERROR`.
      #
      # @return [Boolean]
      attr_reader :available

      # True if the Big Segment store is available, but has not been updated within the amount of time
      # specified by {BigSegmentsConfig#stale_after}.
      #
      # This may indicate that the LaunchDarkly Relay Proxy, which populates the store, has stopped
      # running or has become unable to receive fresh data from LaunchDarkly. Any feature flag
      # evaluations that reference a Big Segment will be using the last known data, which may be out
      # of date. Also, the {EvaluationReason} associated with those evaluations will have a
      # `big_segments_status` of `STALE`.
      #
      # @return [Boolean]
      attr_reader :stale

      def ==(other)
        self.available == other.available && self.stale == other.stale
      end
    end

    #
    # An interface for querying the status of a Big Segment store.
    #
    # The Big Segment store is the component that receives information about Big Segments, normally
    # from a database populated by the LaunchDarkly Relay Proxy. Big Segments are a specific type
    # of segments. For more information, read the LaunchDarkly documentation:
    # https://docs.launchdarkly.com/home/users/big-segments
    #
    # An implementation of this interface is returned by {LDClient#big_segment_store_status_provider}.
    # Application code never needs to implement this interface.
    #
    # There are two ways to interact with the status. One is to simply get the current status; if its
    # `available` property is true, then the SDK is able to evaluate context membership in Big Segments,
    # and the `stale`` property indicates whether the data might be out of date.
    #
    # The other way is to subscribe to status change notifications. Applications may wish to know if
    # there is an outage in the Big Segment store, or if it has become stale (the Relay Proxy has
    # stopped updating it with new data), since then flag evaluations that reference a Big Segment
    # might return incorrect values. To allow finding out about status changes as soon as possible,
    # `BigSegmentStoreStatusProvider` mixes in Ruby's
    # [Observable](https://docs.ruby-lang.org/en/2.5.0/Observable.html) module to provide standard
    # methods such as `add_observer`. Observers will be called with a new {BigSegmentStoreStatus}
    # value whenever the status changes.
    #
    # @example Getting the current status
    #   status = client.big_segment_store_status_provider.status
    #
    # @example Subscribing to status notifications
    #   client.big_segment_store_status_provider.add_observer(self, :big_segments_status_changed)
    #
    #   def big_segments_status_changed(new_status)
    #     puts "Big segment store status is now: #{new_status}"
    #   end
    #
    module BigSegmentStoreStatusProvider
      include Observable
      #
      # Gets the current status of the store, if known.
      #
      # @return [BigSegmentStoreStatus] the status, or nil if the SDK has not yet queried the Big
      #   Segment store status
      #
      def status
      end
    end

    module DataSource
      #
      # An interface for querying the status of the SDK's data source. The data
      # source is the component that receives updates to feature flag data;
      # normally this is a streaming connection, but it could be polling or
      # file data depending on your configuration.
      #
      # An implementation of this interface is returned by
      # {LaunchDarkly::LDClient#data_source_status_provider}. Application code
      # never needs to implement this interface.
      #
      module StatusProvider
        #
        # Returns the current status of the data source.
        #
        # All of the built-in data source implementations are guaranteed to update this status whenever they
        # successfully initialize, encounter an error, or recover after an error.
        #
        # For a custom data source implementation, it is the responsibility of the data source to push
        # status updates to the SDK; if it does not do so, the status will always be reported as
        # {Status::INITIALIZING}.
        #
        # @return [Status]
        #
        def status
        end

        #
        # Subscribes for notifications of status changes.
        #
        # The listener will be notified whenever any property of the status has changed. See {Status} for an
        # explanation of the meaning of each property and what could cause it to change.
        #
        # Notifications will be dispatched on a worker thread. It is the listener's responsibility to return as soon as
        # possible so as not to block subsequent notifications.
        #
        # @param [#update] the listener to add
        #
        def add_listener(listener) end

        #
        # Unsubscribes from notifications of status changes.
        #
        def remove_listener(listener) end
      end

      #
      # Interface that a data source implementation will use to push data into
      # the SDK.
      #
      # The data source interacts with this object, rather than manipulating
      # the data store directly, so that the SDK can perform any other
      # necessary operations that must happen when data is updated.
      #
      module UpdateSink
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
        def init(all_data) end

        #
        # Attempt to add an entity, or update an existing entity with the same key. An update
        # should only succeed if the new item's `:version` is greater than the old one;
        # otherwise, the method should do nothing.
        #
        # @param kind [Object]  the kind of entity to add or update
        # @param item [Hash]  the entity to add or update
        # @return [void]
        #
        def upsert(kind, item) end

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
        def delete(kind, key, version) end

        #
        # Informs the SDK of a change in the data source's status.
        #
        # Data source implementations should use this method if they have any
        # concept of being in a valid state, a temporarily disconnected state,
        # or a permanently stopped state.
        #
        # If `new_state` is different from the previous state, and/or
        # `new_error` is non-null, the SDK will start returning the new status
        # (adding a timestamp for the change) from {StatusProvider#status}, and
        # will trigger status change events to any registered listeners.
        #
        # A special case is that if {new_state} is {Status::INTERRUPTED}, but the
        # previous state was {Status::INITIALIZING}, the state will remain at
        # {Status::INITIALIZING} because {Status::INTERRUPTED} is only meaningful
        # after a successful startup.
        #
        # @param new_state [Symbol]
        # @param new_error [ErrorInfo, nil]
        #
        def update_status(new_state, new_error) end
      end

      #
      # Information about the data source's status and about the last status change.
      #
      class Status
        #
        # The initial state of the data source when the SDK is being initialized.
        #
        # If it encounters an error that requires it to retry initialization, the state will remain at
        # {INITIALIZING} until it either succeeds and becomes {VALID}, or permanently fails and
        # becomes {OFF}.
        #

        INITIALIZING = :initializing

        #
        # Indicates that the data source is currently operational and has not had any problems since the
        # last time it received data.
        #
        # In streaming mode, this means that there is currently an open stream connection and that at least
        # one initial message has been received on the stream. In polling mode, it means that the last poll
        # request succeeded.
        #
        VALID = :valid

        #
        # Indicates that the data source encountered an error that it will attempt to recover from.
        #
        # In streaming mode, this means that the stream connection failed, or had to be dropped due to some
        # other error, and will be retried after a backoff delay. In polling mode, it means that the last poll
        # request failed, and a new poll request will be made after the configured polling interval.
        #
        INTERRUPTED = :interrupted

        #
        # Indicates that the data source has been permanently shut down.
        #
        # This could be because it encountered an unrecoverable error (for instance, the LaunchDarkly service
        # rejected the SDK key; an invalid SDK key will never become valid), or because the SDK client was
        # explicitly shut down.
        #
        OFF = :off

        # @return [Symbol] The basic state
        attr_reader :state
        # @return [Time] timestamp of the last state transition
        attr_reader :state_since
        # @return [ErrorInfo, nil] a description of the last error or nil if no errors have occurred since startup
        attr_reader :last_error

        def initialize(state, state_since, last_error)
          @state = state
          @state_since = state_since
          @last_error = last_error
        end
      end

      #
      # A description of an error condition that the data source encountered.
      #
      class ErrorInfo
        #
        # An unexpected error, such as an uncaught exception, further described by {#message}.
        #
        UNKNOWN = :unknown

        #
        # An I/O error such as a dropped connection.
        #
        NETWORK_ERROR = :network_error

        #
        # The LaunchDarkly service returned an HTTP response with an error status, available with
        # {#status_code}.
        #
        ERROR_RESPONSE = :error_response

        #
        # The SDK received malformed data from the LaunchDarkly service.
        #
        INVALID_DATA = :invalid_data

        #
        # The data source itself is working, but when it tried to put an update into the data store, the data
        # store failed (so the SDK may not have the latest data).
        #
        # Data source implementations do not need to report this kind of error; it will be automatically
        # reported by the SDK when exceptions are detected.
        #
        STORE_ERROR = :store_error

        # @return [Symbol] the general category of the error
        attr_reader :kind
        # @return [Integer] an HTTP status or zero
        attr_reader :status_code
        # @return [String, nil] message an error message if applicable, or nil
        attr_reader :message
        # @return [Time] time the error timestamp
        attr_reader :time

        def initialize(kind, status_code, message, time)
          @kind = kind
          @status_code = status_code
          @message = message
          @time = time
        end
      end
    end

    #
    # Namespace for feature-flag based technology migration support.
    #
    module Migrations
      #
      # A migrator is the interface through which migration support is executed. A migrator is configured through the
      # {LaunchDarkly::Migrations::MigratorBuilder} class.
      #
      module Migrator
        #
        # Uses the provided flag key and context to execute a migration-backed read operation.
        #
        # @param key [String]
        # @param context [LaunchDarkly::LDContext]
        # @param default_stage [Symbol]
        # @param payload [Object, nil]
        #
        # @return [LaunchDarkly::Migrations::OperationResult]
        #
        def read(key, context, default_stage, payload = nil) end

        #
        # Uses the provided flag key and context to execute a migration-backed write operation.
        #
        # @param key [String]
        # @param context [LaunchDarkly::LDContext]
        # @param default_stage [Symbol]
        # @param payload [Object, nil]
        #
        # @return [LaunchDarkly::Migrations::WriteResult]
        #
        def write(key, context, default_stage, payload = nil) end
      end

      #
      # An OpTracker is responsible for managing the collection of measurements that which a user might wish to record
      # throughout a migration-assisted operation.
      #
      # Example measurements include latency, errors, and consistency.
      #
      # This data can be provided to the {LaunchDarkly::LDClient.track_migration_op} method to relay this metric
      # information upstream to LaunchDarkly services.
      #
      module OpTracker
        #
        # Sets the migration related operation associated with these tracking measurements.
        #
        # @param [Symbol] op The read or write operation symbol.
        #
        def operation(op) end

        #
        # Allows recording which origins were called during a migration.
        #
        # @param [Symbol] origin Designation for the old or new origin.
        #
        def invoked(origin) end

        #
        # Allows recording the results of a consistency check.
        #
        # This method accepts a callable which should take no parameters and return a single boolean to represent the
        # consistency check results for a read operation.
        #
        # A callable is provided in case sampling rules do not require consistency checking to run. In this case, we can
        # avoid the overhead of a function by not using the callable.
        #
        # @param [#call] is_consistent closure to return result of comparison check
        #
        def consistent(is_consistent) end

        #
        # Allows recording whether an error occurred during the operation.
        #
        # @param [Symbol] origin Designation for the old or new origin.
        #
        def error(origin) end

        #
        # Allows tracking the recorded latency for an individual operation.
        #
        # @param [Symbol] origin Designation for the old or new origin.
        # @param [Float] duration Duration measurement in milliseconds (ms).
        #
        def latency(origin, duration) end

        #
        # Creates an instance of {LaunchDarkly::Impl::MigrationOpEventData}.
        #
        # @return [LaunchDarkly::Impl::MigrationOpEvent, String] A migration op event or a string describing the error.
        # failure.
        #
        def build
        end
      end
    end

    module Hooks
      #
      # Mixin for extending SDK functionality via hooks.
      #
      # All provided hook implementations **MUST** include this mixin. Hooks without this mixin will be ignored.
      #
      # This mixin includes default implementations for all hook handlers. This allows LaunchDarkly to expand the list
      # of hook handlers without breaking customer integrations.
      #
      module Hook
        #
        # Get metadata about the hook implementation.
        #
        # @return [Metadata]
        #
        def metadata
          Metadata.new('UNDEFINED')
        end

        #
        # The before method is called during the execution of a variation method before the flag value has been
        # determined. The method is executed synchronously.
        #
        # @param evaluation_series_context [EvaluationSeriesContext] Contains information about the evaluation being
        # performed. This is not mutable.
        # @param data [Hash] A record associated with each stage of hook invocations. Each stage is called with the data
        # of the previous stage for a series. The input record should not be modified.
        # @return [Hash] Data to use when executing the next state of the hook in the evaluation series.
        #
        def before_evaluation(evaluation_series_context, data)
          data
        end

        #
        # The after method is called during the execution of the variation method # after the flag value has been
        # determined. The method is executed synchronously.
        #
        # @param evaluation_series_context [EvaluationSeriesContext] Contains read-only information about the evaluation
        # being performed.
        # @param data [Hash] A record associated with each stage of hook invocations. Each stage is called with the data
        # of the previous stage for a series.
        # @param detail [LaunchDarkly::EvaluationDetail] The result of the evaluation. This value should not be
        # modified.
        # @return [Hash] Data to use when executing the next state of the hook in the evaluation series.
        #
        def after_evaluation(evaluation_series_context, data, detail)
          data
        end
      end

      #
      # Metadata data class used for annotating hook implementations.
      #
      class Metadata
        attr_reader :name

        def initialize(name)
          @name = name
        end
      end

      #
      # Contextual information that will be provided to handlers during evaluation series.
      #
      class EvaluationSeriesContext
        attr_reader :key
        attr_reader :context
        attr_reader :default_value
        attr_reader :method

        #
        # @param key [String]
        # @param context [LaunchDarkly::LDContext]
        # @param default_value [any]
        # @param method [Symbol]
        #
        def initialize(key, context, default_value, method)
          @key = key
          @context = context
          @default_value = default_value
          @method = method
        end
      end
    end
  end
end
