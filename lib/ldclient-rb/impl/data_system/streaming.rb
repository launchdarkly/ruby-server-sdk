# frozen_string_literal: true

require "ldclient-rb/interfaces"
require "ldclient-rb/interfaces/data_system"
require "ldclient-rb/impl/data_system"
require "ldclient-rb/impl/data_system/protocolv2"
require "ldclient-rb/impl/data_system/polling"  # For shared constants
require "ldclient-rb/impl/util"
require "concurrent"
require "json"
require "uri"
require "ld-eventsource"

module LaunchDarkly
  module Impl
    module DataSystem
      FDV2_STREAMING_ENDPOINT = "/sdk/stream"

      # Allows for up to 5 minutes to elapse without any data sent across the stream.
      # The heartbeats sent as comments on the stream will keep this from triggering.
      STREAM_READ_TIMEOUT = 5 * 60

      #
      # StreamingDataSource is a Synchronizer that uses Server-Sent Events (SSE)
      # to receive real-time updates from LaunchDarkly's Flag Delivery services.
      #
      class StreamingDataSource
        include LaunchDarkly::Interfaces::DataSystem::Synchronizer

        attr_reader :name

        #
        # @param sdk_key [String]
        # @param config [LaunchDarkly::Config]
        # @param sse_client_builder [Proc] Optional SSE client builder for testing
        #
        def initialize(sdk_key, config, sse_client_builder = nil)
          @sdk_key = sdk_key
          @config = config
          @logger = config.logger
          @name = "StreamingDataSourceV2"
          @sse_client_builder = sse_client_builder || method(:create_sse_client)
          @sse = nil
          @running = Concurrent::AtomicBoolean.new(false)
          @diagnostic_accumulator = nil
          @connection_attempt_start_time = nil
        end

        #
        # Sets the diagnostic accumulator for streaming initialization metrics.
        #
        # @param diagnostic_accumulator [Object]
        #
        def set_diagnostic_accumulator(diagnostic_accumulator)
          @diagnostic_accumulator = diagnostic_accumulator
        end

        #
        # sync begins the synchronization process for the data source, yielding
        # Update objects until the connection is closed or an unrecoverable error
        # occurs.
        #
        # @param ss [LaunchDarkly::Interfaces::DataSystem::SelectorStore]
        # @yieldparam update [LaunchDarkly::Interfaces::DataSystem::Update]
        #
        def sync(ss)
          @logger.info { "[LDClient] Starting StreamingDataSourceV2 synchronizer" }
          @running.make_true
          log_connection_started

          change_set_builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
          envid = nil
          fallback = false

          # Always use the builder to create the SSE client
          @sse = @sse_client_builder.call(@config, ss)
          unless @sse
            @logger.error { "[LDClient] Failed to create SSE client for streaming updates" }
            return
          end

          # Set up event handlers
          @sse.on_event do |event|
            begin
              update = process_message(event, change_set_builder, envid)
              if update
                log_connection_result(true)
                @connection_attempt_start_time = nil
                yield update
              end
            rescue JSON::ParserError => e
              @logger.info { "[LDClient] Error while handling stream event; will restart stream: #{e}" }
              yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                  LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN,
                  0,
                  e.to_s,
                  Time.now
                ),
                environment_id: envid
              )
            rescue => e
              @logger.info { "[LDClient] Error while handling stream event; will restart stream: #{e}" }
              yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                  LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN,
                  0,
                  e.to_s,
                  Time.now
                ),
                environment_id: envid
              )
            end
          end

          @sse.on_error do |error|
            log_connection_result(false)

            # Extract envid from error headers if available
            if error.respond_to?(:headers) && error.headers
              envid_from_error = error.headers[LD_ENVID_HEADER]
              envid = envid_from_error if envid_from_error

              if error.headers[LD_FD_FALLBACK_HEADER] == 'true'
                fallback = true
              end
            end

            update, _should_continue = handle_error(error, envid, fallback)
            yield update if update
          end

          @sse.start
        end

        #
        # Stops the streaming synchronizer.
        #
        def stop
          @logger.info { "[LDClient] Stopping StreamingDataSourceV2 synchronizer" }
          @running.make_false
          @sse&.close
        end

        private

        #
        # Creates an SSE client configured for the LaunchDarkly streaming endpoint.
        # This is the default builder used when no custom builder is provided.
        #
        # @param config [LaunchDarkly::Config] (unused, but matches builder signature)
        # @param ss [LaunchDarkly::Interfaces::DataSystem::SelectorStore]
        # @return [SSE::Client]
        #
        def create_sse_client(_config, ss)
          base_uri = @config.stream_uri + FDV2_STREAMING_ENDPOINT
          headers = Impl::Util.default_http_headers(@sdk_key, @config)
          opts = {
            headers: headers,
            read_timeout: STREAM_READ_TIMEOUT,
            logger: @logger,
            socket_factory: @config.socket_factory,
            reconnect_time: @config.initial_reconnect_delay,
          }

          SSE::Client.new(base_uri, **opts) do |client|
            # Use dynamic query parameters that are evaluated on each connection/reconnection
            client.query_params do
              selector = ss.selector
              {
                "filter" => @config.payload_filter_key,
                "basis" => (selector.state if selector&.defined?),
              }.compact
            end
          end
        end

        #
        # Processes a single SSE message and returns an Update if applicable.
        #
        # @param message [SSE::StreamEvent]
        # @param change_set_builder [LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder]
        # @param envid [String, nil]
        # @return [LaunchDarkly::Interfaces::DataSystem::Update, nil]
        #
        def process_message(message, change_set_builder, envid)
          event_type = message.type

          # Handle heartbeat - SSE library may use symbol or string
          if event_type == :heartbeat || event_type == LaunchDarkly::Interfaces::DataSystem::EventName::HEARTBEAT
            return nil
          end

          @logger.debug { "[LDClient] Stream received #{event_type} message: #{message.data}" }

          # Convert symbol to string for comparison
          event_name = event_type.is_a?(Symbol) ? event_type.to_s.tr('_', '-') : event_type

          case event_name
          when LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.from_h(JSON.parse(message.data, symbolize_names: true))
            change_set_builder.start(server_intent.payload.code)

            if server_intent.payload.code == LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE
              change_set_builder.expect_changes
              return LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
                environment_id: envid
              )
            end
            nil

          when LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT
            put = LaunchDarkly::Impl::DataSystem::ProtocolV2::PutObject.from_h(JSON.parse(message.data, symbolize_names: true))
            change_set_builder.add_put(put.kind, put.key, put.version, put.object)
            nil

          when LaunchDarkly::Interfaces::DataSystem::EventName::DELETE_OBJECT
            delete_object = LaunchDarkly::Impl::DataSystem::ProtocolV2::DeleteObject.from_h(JSON.parse(message.data, symbolize_names: true))
            change_set_builder.add_delete(delete_object.kind, delete_object.key, delete_object.version)
            nil

          when LaunchDarkly::Interfaces::DataSystem::EventName::GOODBYE
            goodbye = LaunchDarkly::Impl::DataSystem::ProtocolV2::Goodbye.from_h(JSON.parse(message.data, symbolize_names: true))
            unless goodbye.silent
              @logger.error { "[LDClient] SSE server received error: #{goodbye.reason} (catastrophe: #{goodbye.catastrophe})" }
            end
            nil

          when LaunchDarkly::Interfaces::DataSystem::EventName::ERROR
            error = LaunchDarkly::Impl::DataSystem::ProtocolV2::Error.from_h(JSON.parse(message.data, symbolize_names: true))
            @logger.error { "[LDClient] Error on #{error.payload_id}: #{error.reason}" }

            # Reset any previous change events but continue with last server intent
            change_set_builder.reset
            nil

          when LaunchDarkly::Interfaces::DataSystem::EventName::PAYLOAD_TRANSFERRED
            selector = LaunchDarkly::Interfaces::DataSystem::Selector.from_h(JSON.parse(message.data, symbolize_names: true))
            change_set = change_set_builder.finish(selector)

            LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
              change_set: change_set,
              environment_id: envid
            )

          else
            @logger.info { "[LDClient] Unexpected event found in stream: #{event_type}" }
            nil
          end
        end

        #
        # Handles errors that occur during streaming.
        #
        # @param error [Exception]
        # @param envid [String, nil]
        # @param fallback [Boolean]
        # @return [Array<(LaunchDarkly::Interfaces::DataSystem::Update, Boolean)>] Tuple of (update, should_continue)
        #
        def handle_error(error, envid, fallback)
          return [nil, false] unless @running.value

          update = nil

          case error
          when JSON::ParserError
            @logger.error { "[LDClient] Unexpected error on stream connection: #{error}, will retry" }

            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
              error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA,
                0,
                error.to_s,
                Time.now
              ),
              environment_id: envid
            )

          when SSE::Errors::HTTPStatusError
            error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
              LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE,
              error.status,
              Impl::Util.http_error_message(error.status, "stream connection", "will retry"),
              Time.now
            )

            if fallback
              update = LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
                error: error_info,
                revert_to_fdv1: true,
                environment_id: envid
              )
              return [update, false]
            end

            http_error_message_result = Impl::Util.http_error_message(error.status, "stream connection", "will retry")
            is_recoverable = Impl::Util.http_error_recoverable?(error.status)

            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: is_recoverable ? LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED : LaunchDarkly::Interfaces::DataSource::Status::OFF,
              error: error_info,
              environment_id: envid
            )

            unless is_recoverable
              @logger.error { "[LDClient] #{http_error_message_result}" }
              stop
              return [update, false]
            end

            @logger.warn { "[LDClient] #{http_error_message_result}" }

          when SSE::Errors::HTTPContentTypeError, SSE::Errors::HTTPProxyError, SSE::Errors::ReadTimeoutError
            @logger.warn { "[LDClient] Network error on stream connection: #{error}, will retry" }

            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
              error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                LaunchDarkly::Interfaces::DataSource::ErrorInfo::NETWORK_ERROR,
                0,
                error.to_s,
                Time.now
              ),
              environment_id: envid
            )

          else
            @logger.warn { "[LDClient] Unexpected error on stream connection: #{error}, will retry" }

            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
              error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN,
                0,
                error.to_s,
                Time.now
              ),
              environment_id: envid
            )
          end

          [update, true]
        end

        def log_connection_started
          @connection_attempt_start_time = Impl::Util.current_time_millis
        end

        def log_connection_result(is_success)
          if !@diagnostic_accumulator.nil? && @connection_attempt_start_time && @connection_attempt_start_time > 0
            current_time = Impl::Util.current_time_millis
            elapsed = current_time - @connection_attempt_start_time
            @diagnostic_accumulator.record_stream_init(@connection_attempt_start_time, !is_success, elapsed >= 0 ? elapsed : 0)
            @connection_attempt_start_time = 0
          end
        end
      end

      #
      # Builder for a StreamingDataSource.
      #
      class StreamingDataSourceBuilder
        #
        # @param sdk_key [String]
        # @param config [LaunchDarkly::Config]
        #
        def initialize(sdk_key, config)
          @sdk_key = sdk_key
          @config = config
          @sse_client_builder = nil
        end

        #
        # Sets a custom SSE client builder for testing.
        #
        # @param sse_client_builder [Proc]
        # @return [StreamingDataSourceBuilder]
        #
        def sse_client_builder(sse_client_builder)
          @sse_client_builder = sse_client_builder
          self
        end

        #
        # Builds the StreamingDataSource with the configured parameters.
        #
        # @return [StreamingDataSource]
        #
        def build
          StreamingDataSource.new(@sdk_key, @config, @sse_client_builder)
        end
      end
    end
  end
end
