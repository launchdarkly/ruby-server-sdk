require "ldclient-rb/impl/model/serialization"

require "concurrent/atomics"
require "json"
require "ld-eventsource"

module LaunchDarkly
  # @private
  PUT = :put
  # @private
  PATCH = :patch
  # @private
  DELETE = :delete
  # @private
  READ_TIMEOUT_SECONDS = 300  # 5 minutes; the stream should send a ping every 3 minutes

  # @private
  KEY_PATHS = {
    FEATURES => "/flags/",
    SEGMENTS => "/segments/",
  }

  # @private
  class StreamProcessor
    def initialize(sdk_key, config, diagnostic_accumulator = nil)
      @sdk_key = sdk_key
      @config = config
      @data_source_update_sink = config.data_source_update_sink
      @feature_store = config.feature_store
      @initialized = Concurrent::AtomicBoolean.new(false)
      @started = Concurrent::AtomicBoolean.new(false)
      @stopped = Concurrent::AtomicBoolean.new(false)
      @ready = Concurrent::Event.new
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
        reconnect_time: @config.initial_reconnect_delay,
      }
      log_connection_started

      uri = Util.add_payload_filter_key(@config.stream_uri + "/all", @config)
      @es = SSE::Client.new(uri, **opts) do |conn|
        conn.on_event { |event| process_message(event) }
        conn.on_error { |err|
          log_connection_result(false)
          case err
          when SSE::Errors::HTTPStatusError
            status = err.status
            error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
              LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE, status, nil, Time.now)
            message = Util.http_error_message(status, "streaming connection", "will retry")
            @config.logger.error { "[LDClient] #{message}" }

            if Util.http_error_recoverable?(status)
              @data_source_update_sink&.update_status(
                LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                error_info
              )
            else
              @ready.set  # if client was waiting on us, make it stop waiting - has no effect if already set
              stop_with_error_info error_info
            end
          when SSE::Errors::HTTPContentTypeError, SSE::Errors::HTTPProxyError, SSE::Errors::ReadTimeoutError
            @data_source_update_sink&.update_status(
              LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
              LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(LaunchDarkly::Interfaces::DataSource::ErrorInfo::NETWORK_ERROR, 0, err.to_s, Time.now)
            )

          else
            @data_source_update_sink&.update_status(
              LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
              LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN, 0, err.to_s, Time.now)
            )
          end
        }
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
        @data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::OFF, error_info)
        @config.logger.info { "[LDClient] Stream connection stopped" }
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
          for kind in [FEATURES, SEGMENTS]
            key = key_for_path(kind, data[:path])
            if key
              item = Impl::Model.deserialize(kind, data[:data], @config.logger)
              update_sink_or_data_store.upsert(kind, item)
              break
            end
          end
        elsif method == DELETE
          data = JSON.parse(message.data, symbolize_names: true)
          for kind in [FEATURES, SEGMENTS]
            key = key_for_path(kind, data[:path])
            if key
              update_sink_or_data_store.delete(kind, key, data[:version])
              break
            end
          end
        else
          @config.logger.warn { "[LDClient] Unknown message received: #{method}" }
        end

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
