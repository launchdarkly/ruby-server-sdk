module LaunchDarkly
  module Impl
    #
    # Mixin that defines the required methods of a data system implementation. The data system
    # is responsible for managing the SDK's data model, including storage, retrieval, and change
    # detection for feature flag configurations.
    #
    # This module also contains supporting classes and additional mixins for data system
    # implementations, such as DataAvailability, Update, and protocol-specific mixins.
    #
    # For operations that can fail, use {LaunchDarkly::Result} from util.rb.
    #
    # Application code should not need to implement this directly; it is used internally by the
    # SDK's data system implementations.
    #
    # @private
    #
    module DataSystem
      #
      # Starts the data system.
      #
      # This method will return immediately. The returned event will be set when the system
      # has reached an initial state (either permanently failed, e.g. due to bad auth, or succeeded).
      #
      # @return [Concurrent::Event] Event that will be set when initialization is complete
      #
      def start
        raise NotImplementedError, "#{self.class} must implement #start"
      end

      #
      # Halts the data system. Should be called when the client is closed to stop any long running
      # operations.
      #
      # @return [void]
      #
      def stop
        raise NotImplementedError, "#{self.class} must implement #stop"
      end

      #
      # Returns an interface for tracking the status of the data source.
      #
      # The data source is the mechanism that the SDK uses to get feature flag configurations, such
      # as a streaming connection (the default) or poll requests.
      #
      # @return [LaunchDarkly::Interfaces::DataSource::StatusProvider]
      #
      def data_source_status_provider
        raise NotImplementedError, "#{self.class} must implement #data_source_status_provider"
      end

      #
      # Returns an interface for tracking the status of a persistent data store.
      #
      # The provider has methods for checking whether the data store is (as far
      # as the SDK knows) currently operational, tracking changes in this
      # status, and getting cache statistics. These are only relevant for a
      # persistent data store; if you are using an in-memory data store, then
      # this method will return a stub object that provides no information.
      #
      # @return [LaunchDarkly::Interfaces::DataStore::StatusProvider]
      #
      def data_store_status_provider
        raise NotImplementedError, "#{self.class} must implement #data_store_status_provider"
      end

      #
      # Returns an interface for tracking changes in feature flag configurations.
      #
      # @return [LaunchDarkly::Interfaces::FlagTracker]
      #
      def flag_tracker
        raise NotImplementedError, "#{self.class} must implement #flag_tracker"
      end

      #
      # Indicates what form of data is currently available.
      #
      # @return [Symbol] One of DataAvailability constants
      #
      def data_availability
        raise NotImplementedError, "#{self.class} must implement #data_availability"
      end

      #
      # Indicates the ideal form of data attainable given the current configuration.
      #
      # @return [Symbol] One of DataAvailability constants
      #
      def target_availability
        raise NotImplementedError, "#{self.class} must implement #target_availability"
      end

      #
      # Returns the data store used by the data system.
      #
      # @return [Object] The read-only store
      #
      def store
        raise NotImplementedError, "#{self.class} must implement #store"
      end

      #
      # Injects the flag value evaluation function used by the flag tracker to
      # compute FlagValueChange events. The function signature should be
      # (key, context) -> value.
      #
      # This method must be called after initialization to enable the flag tracker
      # to compute value changes for flag change listeners.
      #
      # @param eval_fn [Proc] The evaluation function
      # @return [void]
      #
      def set_flag_value_eval_fn(eval_fn)
        raise NotImplementedError, "#{self.class} must implement #set_flag_value_eval_fn"
      end

      #
      # Sets the diagnostic accumulator for streaming initialization metrics.
      # This should be called before start() to ensure metrics are collected.
      #
      # @param diagnostic_accumulator [DiagnosticAccumulator] The diagnostic accumulator
      # @return [void]
      #
      def set_diagnostic_accumulator(diagnostic_accumulator)
        raise NotImplementedError, "#{self.class} must implement #set_diagnostic_accumulator"
      end

      #
      # Represents the availability of data in the SDK.
      #
      class DataAvailability
        # The SDK has no data and will evaluate flags using the application-provided default values.
        DEFAULTS = :defaults

        # The SDK has data, not necessarily the latest, which will be used to evaluate flags.
        CACHED = :cached

        # The SDK has obtained, at least once, the latest known data from LaunchDarkly.
        REFRESHED = :refreshed

        ALL = [DEFAULTS, CACHED, REFRESHED].freeze

        #
        # Returns whether this availability level is **at least** as good as the other.
        #
        # @param [Symbol] self_level The current availability level
        # @param [Symbol] other The other availability level to compare against
        # @return [Boolean] true if this availability level is at least as good as the other
        #
        def self.at_least?(self_level, other)
          return true if self_level == other
          return true if self_level == REFRESHED
          return true if self_level == CACHED && other == DEFAULTS

          false
        end
      end

      #
      # Mixin that defines the required methods of a diagnostic accumulator implementation.
      # The diagnostic accumulator is used for collecting and reporting diagnostic events
      # to LaunchDarkly for monitoring SDK performance and behavior.
      #
      # Application code should not need to implement this directly; it is used internally by the SDK.
      #
      module DiagnosticAccumulator
        #
        # Record a stream initialization.
        #
        # @param timestamp [Float] The timestamp
        # @param duration [Float] The duration
        # @param failed [Boolean] Whether it failed
        # @return [void]
        #
        def record_stream_init(timestamp, duration, failed)
          raise NotImplementedError, "#{self.class} must implement #record_stream_init"
        end

        #
        # Record events in a batch.
        #
        # @param events_in_batch [Integer] The number of events
        # @return [void]
        #
        def record_events_in_batch(events_in_batch)
          raise NotImplementedError, "#{self.class} must implement #record_events_in_batch"
        end

        #
        # Create an event and reset the accumulator.
        #
        # @param dropped_events [Integer] The number of dropped events
        # @param deduplicated_users [Integer] The number of deduplicated users
        # @return [Object] The diagnostic event
        #
        def create_event_and_reset(dropped_events, deduplicated_users)
          raise NotImplementedError, "#{self.class} must implement #create_event_and_reset"
        end
      end

      #
      # Mixin that defines the required methods for components that can receive a diagnostic accumulator.
      # Components that include this mixin can report diagnostic information to LaunchDarkly for
      # monitoring SDK performance and behavior.
      #
      # Application code should not need to implement this directly; it is used internally by the SDK.
      #
      module DiagnosticSource
        #
        # Set the diagnostic_accumulator to be used for reporting diagnostic events.
        #
        # @param diagnostic_accumulator [DiagnosticAccumulator] The accumulator
        # @return [void]
        #
        def set_diagnostic_accumulator(diagnostic_accumulator)
          raise NotImplementedError, "#{self.class} must implement #set_diagnostic_accumulator"
        end
      end

      #
      # Mixin that defines the required methods of an initializer implementation. An initializer
      # is a component capable of retrieving a single data result, such as from the LaunchDarkly
      # polling API.
      #
      # The intent of initializers is to quickly fetch an initial set of data, which may be stale
      # but is fast to retrieve. This initial data serves as a foundation for a Synchronizer to
      # build upon, enabling it to provide updates as new changes occur.
      #
      # Application code should not need to implement this directly; it is used internally by the SDK.
      #
      module Initializer
        #
        # Fetch should retrieve the initial data set for the data source, returning
        # a Basis object on success, or an error message on failure.
        #
        # @return [LaunchDarkly::Result] A Result containing either a Basis or an error message
        #
        def fetch
          raise NotImplementedError, "#{self.class} must implement #fetch"
        end
      end

      #
      # Update represents the results of a synchronizer's ongoing sync method.
      #
      class Update
        # @return [Symbol] The state of the data source
        attr_reader :state

        # @return [ChangeSet, nil] The change set if available
        attr_reader :change_set

        # @return [LaunchDarkly::Interfaces::DataSource::ErrorInfo, nil] Error information if applicable
        attr_reader :error

        # @return [Boolean] Whether to revert to FDv1
        attr_reader :revert_to_fdv1

        # @return [String, nil] The environment ID if available
        attr_reader :environment_id

        #
        # @param state [Symbol] The state of the data source
        # @param change_set [ChangeSet, nil] The change set if available
        # @param error [LaunchDarkly::Interfaces::DataSource::ErrorInfo, nil] Error information if applicable
        # @param revert_to_fdv1 [Boolean] Whether to revert to FDv1
        # @param environment_id [String, nil] The environment ID if available
        #
        def initialize(state:, change_set: nil, error: nil, revert_to_fdv1: false, environment_id: nil)
          @state = state
          @change_set = change_set
          @error = error
          @revert_to_fdv1 = revert_to_fdv1
          @environment_id = environment_id
        end
      end

      #
      # Mixin that defines the required methods of a synchronizer implementation. A synchronizer
      # is a component capable of synchronizing data from an external data source, such as a
      # streaming or polling API.
      #
      # It is responsible for yielding Update objects that represent the current state of the
      # data source, including any changes that have occurred since the last synchronization.
      #
      # Application code should not need to implement this directly; it is used internally by the SDK.
      #
      module Synchronizer
        #
        # Sync should begin the synchronization process for the data source, yielding
        # Update objects until the connection is closed or an unrecoverable error
        # occurs.
        #
        # @yield [Update] Yields Update objects as synchronization progresses
        # @return [void]
        #
        def sync
          raise NotImplementedError, "#{self.class} must implement #sync"
        end
      end
    end
  end
end

