require "ldclient-rb/impl/data_source"
require "ldclient-rb/impl/repeating_task"
require "ldclient-rb/impl/retry_state"
require "ldclient-rb/impl/util"

require "concurrent/atomics"
require "json"
require "thread"

module LaunchDarkly
  module Impl
    module DataSource
      class PollingProcessor
        def initialize(config, requestor)
          @config = config
          @requestor = requestor
          @initialized = Concurrent::AtomicBoolean.new(false)
          @started = Concurrent::AtomicBoolean.new(false)
          @ready = Concurrent::Event.new
          @retry_state = Impl::RetryState.for_polling(@config.poll_interval, @config.logger)
          @task = Impl::RepeatingTask.new(-> { @retry_state.next_delay }, 0, -> { self.poll }, @config.logger, 'LD/PollingDataSource')
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
            all_data, headers = request_all_data
            DataSource.record_environment_id(@config.data_source_update_sink, headers)
            if all_data
              update_sink_or_data_store.init(all_data)
              if @initialized.make_true
                @config.logger.info { "[LDClient] Polling connection initialized" }
                @ready.set
              end
            end
            @retry_state.record_success
            @config.data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
          rescue JSON::ParserError => e
            @retry_state.record_failure(:normal)
            @config.logger.error { "[LDClient] JSON parsing failed for polling response - #{Util.retry_message(@retry_state.next_delay)}" }
            error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
              LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA,
              0,
              e.to_s,
              Time.now
            )
            @config.data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, error_info)
          rescue Impl::DataSource::UnexpectedResponseError => e
            @retry_state.record_failure(Impl::RetryState.classify_http_status(e.status))
            error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
              LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE, e.status, nil, Time.now)
            message = Util.http_error_retry_message(e.status, "polling request", @retry_state.next_delay)
            @config.logger.error { "[LDClient] #{message}" }
            @config.data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, error_info)
          rescue StandardError => e
            @retry_state.record_failure(:normal)
            Impl::Util.log_exception(@config.logger, "Exception while polling - #{Util.retry_message(@retry_state.next_delay)}", e)
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
        # Requestors provided by application code may not be able to report the response headers.
        #
        # @return [Array(Hash, HTTP::Headers, nil)]
        #
        private def request_all_data
          return @requestor.request_all_data_with_headers if @requestor.respond_to?(:request_all_data_with_headers)

          [@requestor.request_all_data, nil]
        end

        #
        # @param [LaunchDarkly::Interfaces::DataSource::ErrorInfo, nil] error_info
        #
        private def stop_with_error_info(error_info = nil)
          @task.stop
          @requestor.stop if @requestor.respond_to?(:stop)
          @config.logger.info { "[LDClient] Polling connection stopped" }
          @config.data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::OFF, error_info)
        end
      end
    end
  end
end

