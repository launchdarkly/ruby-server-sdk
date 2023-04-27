require "ldclient-rb/impl/repeating_task"

require "concurrent/atomics"
require "json"
require "thread"

module LaunchDarkly
  # @private
  class PollingProcessor
    def initialize(config, requestor)
      @config = config
      @requestor = requestor
      @initialized = Concurrent::AtomicBoolean.new(false)
      @started = Concurrent::AtomicBoolean.new(false)
      @ready = Concurrent::Event.new
      @task = Impl::RepeatingTask.new(@config.poll_interval, 0, -> { self.poll }, @config.logger)
    end

    def initialized?
      @initialized.value
    end

    def start
      return @ready unless @started.make_true
      @config.logger.info { "[LDClient] Initializing polling connection" }
      @task.start
      @ready
    end

    def stop
      stop_with_error_info
    end

    def poll
      begin
        all_data = @requestor.request_all_data
        if all_data
          update_sink_or_data_store.init(all_data)
          if @initialized.make_true
            @config.logger.info { "[LDClient] Polling connection initialized" }
            @ready.set
          end
        end
        @config.data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
      rescue JSON::ParserError => e
        @config.logger.error { "[LDClient] JSON parsing failed for polling response." }
        error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
          LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA,
          0,
          e.to_s,
          Time.now
        )
        @config.data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, error_info)
      rescue UnexpectedResponseError => e
        error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
          LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE, e.status, nil, Time.now)
        message = Util.http_error_message(e.status, "polling request", "will retry")
        @config.logger.error { "[LDClient] #{message}" }

        if Util.http_error_recoverable?(e.status)
          @config.data_source_update_sink&.update_status(
            LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
            error_info
          )
        else
          @ready.set  # if client was waiting on us, make it stop waiting - has no effect if already set
          stop_with_error_info error_info
        end
      rescue StandardError => e
        Util.log_exception(@config.logger, "Exception while polling", e)
        @config.data_source_update_sink&.update_status(
          LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
          LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN, 0, e.to_s, Time.now)
        )
      end
    end

    #
    # The original implementation of this class relied on the feature store
    # directly, which we are trying to move away from. Customers who might have
    # instantiated this directly for some reason wouldn't know they have to set
    # the config's sink manually, so we have to fall back to the store if the
    # sink isn't present.
    #
    # The next major release should be able to simplify this structure and
    # remove the need for fall back to the data store because the update sink
    # should always be present.
    #
    private def update_sink_or_data_store
      @config.data_source_update_sink || @config.feature_store
    end

    #
    # @param [LaunchDarkly::Interfaces::DataSource::ErrorInfo, nil] error_info
    #
    private def stop_with_error_info(error_info = nil)
      @task.stop
      @config.logger.info { "[LDClient] Polling connection stopped" }
      @config.data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::OFF, error_info)
    end
  end
end
