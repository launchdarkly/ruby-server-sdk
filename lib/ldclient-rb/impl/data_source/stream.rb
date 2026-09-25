require "ldclient-rb/impl/data_source"
require "ldclient-rb/impl/model/serialization"
require "ldclient-rb/impl/retry_state"
require "ldclient-rb/impl/util"
require "ldclient-rb/in_memory_store"

require "concurrent/atomics"
require "json"
require "ld-eventsource"

module LaunchDarkly
  module Impl
    module DataSource
      PUT = :put
      PATCH = :patch
      DELETE = :delete
      READ_TIMEOUT_SECONDS = 300  # 5 minutes; the stream should send a ping every 3 minutes

      KEY_PATHS = {
        Impl::DataStore::FEATURES => "/flags/",
        Impl::DataStore::SEGMENTS => "/segments/",
      }

      class StreamProcessor
        def initialize(sdk_key, config, diagnostic_accumulator = nil)
          @sdk_key = sdk_key
          @config = config
          @diagnostic_accumulator = diagnostic_accumulator
          @data_source_update_sink = config.data_source_update_sink
          @feature_store = config.feature_store
          @initialized = Concurrent::AtomicBoolean.new(false)
          @started = Concurrent::AtomicBoolean.new(false)
          @stopped = Concurrent::AtomicBoolean.new(false)
          @ready = Concurrent::Event.new
          @stop_event = Concurrent::Event.new
          @retry_state = Impl::RetryState.for_streaming(@config.initial_reconnect_delay, @config.logger)
          @connection_attempt_start_time = 0
        end

        def initialized?
          @initialized.value
        end

        def start
          return @ready unless @started.make_true

          @config.logger.info { "[LDClient] Initializing stream connection" }

          headers = Impl::Util.default_http_headers(@sdk_key, @config)
          opts = {
            headers: headers,
            read_timeout: READ_TIMEOUT_SECONDS,
            logger: @config.logger,
            socket_factory: @config.socket_factory,
            # The SDK waits in the failure handlers instead. This must be an Integer: the SSE client
            # multiplies it by a power of two, and a Float 0.0 becomes NaN once that power overflows.
            reconnect_time: 0,
          }
          log_connection_started

          uri = Impl::Util.add_payload_filter_key(@config.stream_uri + "/all", @config)
          @es = SSE::Client.new(uri, **opts) do |conn|
            conn.on_connect { |response_headers| DataSource.record_environment_id(@data_source_update_sink, response_headers) }
            conn.on_event { |event| process_message(event) }
            conn.on_error { |err| handle_error(err) }
          end

          @ready
        end

        def stop
          stop_with_error_info
        end

        private

        #
        # @param [LaunchDarkly::Interfaces::DataSource::ErrorInfo, nil] error_info
        #
        def stop_with_error_info(error_info = nil)
          if @stopped.make_true
            @es.close
            @stop_event.set
            @data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::OFF, error_info)
            @config.logger.info { "[LDClient] Stream connection stopped" }
          end
        end

        def handle_error(err)
          if err.is_a?(SSE::Errors::HTTPStatusError)
            status = err.status
            error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
              LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE, status, nil, Time.now)
            handle_failure(Impl::RetryState.classify_http_status(status), error_info) do |delay|
              @config.logger.error { "[LDClient] #{Util.http_error_retry_message(status, 'streaming connection', delay)}" }
            end
            return
          end

          if err.is_a?(SSE::Errors::StreamClosedByServerError)
            error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
              LaunchDarkly::Interfaces::DataSource::ErrorInfo::NETWORK_ERROR, 0, err.to_s, Time.now)
            handle_failure(:normal, error_info) do |delay|
              @config.logger.warn { "[LDClient] The server closed the streaming connection - #{Util.retry_message(delay)}" }
            end
            return
          end

          error_kind = case err
                       when SSE::Errors::HTTPContentTypeError, SSE::Errors::HTTPProxyError, SSE::Errors::ReadTimeoutError
                         LaunchDarkly::Interfaces::DataSource::ErrorInfo::NETWORK_ERROR
                       else
                         LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN
                       end
          error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(error_kind, 0, err.to_s, Time.now)
          handle_failure(:normal, error_info) do |delay|
            @config.logger.warn { "[LDClient] Error on streaming connection: #{err} - #{Util.retry_message(delay)}" }
          end
        end

        #
        # Records a failure, reports it, and waits before the next attempt. The SSE client calls this on its
        # worker thread before it reconnects, so the wait is the reconnect delay, and {#stop} ends it at once.
        #
        # @param kind [Symbol] `:normal` or `:unexpected`
        # @param error_info [LaunchDarkly::Interfaces::DataSource::ErrorInfo]
        # @yieldparam delay [Numeric] seconds until the next attempt, for the log message
        #
        def handle_failure(kind, error_info)
          return if @stopped.value

          log_connection_result(false)
          @retry_state.record_failure(kind)
          delay = @retry_state.next_delay
          yield delay
          @data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, error_info)

          @stop_event.wait([delay, Impl::RetryState::MAX_WAIT].min)
          log_connection_started
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
        def update_sink_or_data_store
          @data_source_update_sink || @feature_store
        end

        def process_message(message)
          log_connection_result(true)
          method = message.type
          @config.logger.debug { "[LDClient] Stream received #{method} message: #{message.data}" }

          begin
            if method == PUT
              message = JSON.parse(message.data, symbolize_names: true)
              all_data = Impl::Model.make_all_store_data(message[:data], @config.logger)
              update_sink_or_data_store.init(all_data)
              @initialized.make_true
              @config.logger.info { "[LDClient] Stream initialized" }
              @ready.set
            elsif method == PATCH
              data = JSON.parse(message.data, symbolize_names: true)
              for kind in [Impl::DataStore::FEATURES, Impl::DataStore::SEGMENTS]
                key = key_for_path(kind, data[:path])
                if key
                  item = Impl::Model.deserialize(kind, data[:data], @config.logger)
                  update_sink_or_data_store.upsert(kind, item)
                  break
                end
              end
            elsif method == DELETE
              data = JSON.parse(message.data, symbolize_names: true)
              for kind in [Impl::DataStore::FEATURES, Impl::DataStore::SEGMENTS]
                key = key_for_path(kind, data[:path])
                if key
                  update_sink_or_data_store.delete(kind, key, data[:version])
                  break
                end
              end
            else
              @config.logger.warn { "[LDClient] Unknown message received: #{method}" }
            end

            @retry_state.record_success
            @data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
          rescue JSON::ParserError => e
            @config.logger.error { "[LDClient] JSON parsing failed for method #{method}. Ignoring event." }
            error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
              LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA,
              0,
              e.to_s,
              Time.now
            )
            @data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, error_info)

            # Re-raise the exception so the SSE implementation can catch it and restart the stream.
            raise
          end
        end

        def key_for_path(kind, path)
          path.start_with?(KEY_PATHS[kind]) ? path[KEY_PATHS[kind].length..-1] : nil
        end

        def log_connection_started
          @connection_attempt_start_time = Impl::Util::current_time_millis
        end

        def log_connection_result(is_success)
          if !@diagnostic_accumulator.nil? && @connection_attempt_start_time > 0
            @diagnostic_accumulator.record_stream_init(@connection_attempt_start_time, !is_success,
              Impl::Util::current_time_millis - @connection_attempt_start_time)
            @connection_attempt_start_time = 0
          end
        end
      end
    end
  end
end

