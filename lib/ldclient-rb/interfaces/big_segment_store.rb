require "observer"

module LaunchDarkly
  module Interfaces
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
  end
end
