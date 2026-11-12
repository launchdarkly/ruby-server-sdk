module LaunchDarkly
  module Interfaces
    #
    # Types that describe the status of the data source that the client uses.
    #
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
      # Information about the data source's status and about the last status change.
      #
      class Status
        #
        # The initial state of the data source when the SDK is being initialized.
        #
        # If it encounters an error while it initializes, it retries, and the state remains at
        # {INITIALIZING} until it succeeds and becomes {VALID}. This is also true for an error that needs
        # to be fixed, such as a rejected SDK key. In the FDv2 data system, it can instead become {OFF}
        # after an error it does not retry.
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
        # request failed, and a new poll request will be made after the polling interval, or after a longer
        # backoff delay for unexpected error types.
        #
        INTERRUPTED = :interrupted

        #
        # Indicates that the data source has been permanently shut down.
        #
        # This could be because the SDK client was explicitly shut down. In the FDv2 data system, it can also
        # mean the data source stopped after an error it does not retry.
        #
        # Unless the SDK is configured with {LaunchDarkly::Config#data_system}, no other state follows
        # this one.
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
