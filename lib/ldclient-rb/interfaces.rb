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
        # If {new_state} is different from the previous state, and/or
        # {new_error} is non-null, the SDK will start returning the new status
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
  end
end
