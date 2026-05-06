# frozen_string_literal: true

require "ldclient-rb/interfaces"
require "ldclient-rb/interfaces/data_system"
require "ldclient-rb/impl/data_system"
require "ldclient-rb/impl/data_system/protocolv2"
require "ldclient-rb/impl/data_system/polling"  # For shared constants
require "ldclient-rb/data_system/streaming_data_source_builder"
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
        # @param http_config [HttpConfigOptions] HTTP connection settings
        # @param initial_reconnect_delay [Float] Initial delay before reconnecting after an error
        # @param config [LaunchDarkly::Config] Used for global header settings
        #
        def initialize(sdk_key, http_config, initial_reconnect_delay, config)
          @sdk_key = sdk_key
          @http_config = http_config
          @initial_reconnect_delay = initial_reconnect_delay
          @config = config
          @logger = config.logger
          @name = "StreamingDataSourceV2"
          @sse = nil
          @stopped = Concurrent::Event.new
          @diagnostic_accumulator = nil
          @connection_attempt_start_time = 0
        end

        #
        # Sets the diagnostic accumulator for streaming initialization metrics.
        #
        # @param diagnostic_accumulator [LaunchDarkly::Impl::DiagnosticAccumulator]
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
          log_connection_started

          change_set_builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
          envid = nil
          # The FDv1 Fallback Directive is one-way and terminal: once any
          # connect handshake within this sync invocation carries it, the SDK
          # is committed to engaging FDv1 as soon as the next full payload
          # has been applied. We therefore latch this flag to true on first
          # observation and never reset it -- a mid-sync reconnect whose
          # response no longer carries the directive does NOT cancel a
          # directive seen earlier. This matches the Go and Python SDK
          # implementations, both of which use the same latch pattern.
          #
          # The flag has to bridge two callbacks: on_connect sees the response
          # headers but on_event does not. A local closed over by both blocks
          # is correct because:
          #   1. Scope -- bound to a single sync invocation, so a future sync
          #      starts fresh. (Within this invocation, persistence across
          #      reconnects is the intended semantics, per above.)
          #   2. Thread safety -- ld-eventsource dispatches on_connect,
          #      on_event, and on_error on the same SSE worker thread, so
          #      reads and writes here are single-threaded by construction.
          fdv1_fallback_pending = false

          base_uri = @http_config.base_uri + FDV2_STREAMING_ENDPOINT
          headers = Impl::Util.default_http_headers(@sdk_key, @config)
          opts = {
            headers: headers,
            read_timeout: STREAM_READ_TIMEOUT,
            logger: @logger,
            socket_factory: @http_config.socket_factory,
            reconnect_time: @initial_reconnect_delay,
          }

          @sse = SSE::Client.new(base_uri, **opts) do |client|
            client.on_connect do |headers|
              if headers
                # Per-environment identifier: server sends it on every connect,
                # but it never changes once known so only assign once.
                envid ||= LaunchDarkly::Impl::DataSystem.lookup_header(headers, LD_ENVID_HEADER)
                fdv1_fallback_pending = true if LaunchDarkly::Impl::DataSystem.fdv1_fallback_requested?(headers)
              end
            end

            client.on_event do |event|
              begin
                update = process_message(event, change_set_builder, envid, fdv1_fallback_pending: fdv1_fallback_pending)
                next unless update

                log_connection_result(true)
                @connection_attempt_start_time = 0

                yield update

                # When the FDv1 Fallback Directive rode along on a Valid update, close
                # the stream so the primary synchronizer is stopped once the directive
                # engages. process_message marks the Update with fallback_to_fdv1 only
                # on payloads that complete a transfer, so the consumer has already
                # applied the ChangeSet by the time we get here.
                if update.fallback_to_fdv1
                  fdv1_fallback_pending = false
                  stop
                end
              rescue JSON::ParserError => e
                @logger.info { "[LDClient] Error parsing stream event; will restart stream: #{e}" }
                yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                  state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                  error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                    LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA,
                    0,
                    e.to_s,
                    Time.now
                  ),
                  environment_id: envid
                )

                # Re-raise the exception so the SSE implementation can catch it and restart the stream.
                raise
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

                # Re-raise the exception so the SSE implementation can catch it and restart the stream.
                raise
              end
            end

            client.on_error do |error|
              log_connection_result(false)
              fallback = false

              if error.respond_to?(:headers) && error.headers
                envid ||= LaunchDarkly::Impl::DataSystem.lookup_header(error.headers, LD_ENVID_HEADER)
                fallback = true if LaunchDarkly::Impl::DataSystem.fdv1_fallback_requested?(error.headers)
              end

              update = handle_error(error, envid, fallback)
              yield update if update
            end

            client.query_params do
              selector = ss.selector
              {
                "filter" => @config.payload_filter_key,
                "basis" => (selector.state if selector&.defined?),
              }.compact
            end
          end

          unless @sse
            @logger.error { "[LDClient] Failed to create SSE client for streaming updates" }
            return
          end

          # Client auto-starts in background thread. Wait here until stop() is called.
          @stopped.wait
        end

        #
        # Stops the streaming synchronizer.
        #
        def stop
          @logger.info { "[LDClient] Stopping StreamingDataSourceV2 synchronizer" }
          @sse&.close
          @stopped.set
        end

        #
        # Processes a single SSE message and returns an Update if applicable.
        #
        # @param message [SSE::StreamEvent]
        # @param change_set_builder [LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder]
        # @param envid [String, nil]
        # @param fdv1_fallback_pending [Boolean] true when the connect-time
        #   response headers carried the FDv1 Fallback Directive. When set,
        #   the next Update that completes a payload transfer (TRANSFER_NONE
        #   or PAYLOAD_TRANSFERRED) is marked with fallback_to_fdv1: true so
        #   the consumer can engage the FDv1 Fallback Synchronizer after
        #   applying the in-flight ChangeSet.
        # @return [LaunchDarkly::Interfaces::DataSystem::Update, nil]
        #
        private def process_message(message, change_set_builder, envid, fdv1_fallback_pending: false)
          event_type = message.type

          # Handle heartbeat
          if event_type == LaunchDarkly::Interfaces::DataSystem::EventName::HEARTBEAT
            return nil
          end

          @logger.debug { "[LDClient] Stream received #{event_type} message: #{message.data}" }

          case event_type
          when LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.from_h(JSON.parse(message.data, symbolize_names: true))
            change_set_builder.start(server_intent.payload.code)

            if server_intent.payload.code == LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE
              change_set_builder.expect_changes
              return LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
                environment_id: envid,
                fallback_to_fdv1: fdv1_fallback_pending
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
            @logger.info { "[LDClient] SSE server received goodbye: #{goodbye.reason}" }
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
              environment_id: envid,
              fallback_to_fdv1: fdv1_fallback_pending
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
        # @return [LaunchDarkly::Interfaces::DataSystem::Update, nil]
        #
        private def handle_error(error, envid, fallback)
          return nil if @stopped.set?

          update = nil

          case error
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
                fallback_to_fdv1: true,
                environment_id: envid
              )
              stop
              return update
            end

            is_recoverable = Impl::Util.http_error_recoverable?(error.status)

            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: is_recoverable ? LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED : LaunchDarkly::Interfaces::DataSource::Status::OFF,
              error: error_info,
              environment_id: envid
            )

            unless is_recoverable
              @logger.error { "[LDClient] #{error_info.message}" }
              stop
              return update
            end

            @logger.warn { "[LDClient] #{error_info.message}" }

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

          update
        end

        private def log_connection_started
          @connection_attempt_start_time = Impl::Util.current_time_millis
        end

        private def log_connection_result(is_success)
          return unless @diagnostic_accumulator
          return unless @connection_attempt_start_time > 0

          current_time = Impl::Util.current_time_millis
          elapsed = current_time - @connection_attempt_start_time
          @diagnostic_accumulator.record_stream_init(@connection_attempt_start_time, !is_success, elapsed >= 0 ? elapsed : 0)
          @connection_attempt_start_time = 0
        end
      end

    end
  end
end
