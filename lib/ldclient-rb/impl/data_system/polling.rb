# frozen_string_literal: true

require "ldclient-rb/interfaces"
require "ldclient-rb/interfaces/data_system"
require "ldclient-rb/impl/data_system"
require "ldclient-rb/impl/data_system/protocolv2"
require "ldclient-rb/impl/data_source/requestor"
require "ldclient-rb/impl/util"
require "concurrent"
require "json"
require "uri"
require "http"

module LaunchDarkly
  module Impl
    module DataSystem
      FDV2_POLLING_ENDPOINT = "/sdk/poll"
      FDV1_POLLING_ENDPOINT = "/sdk/latest-all"

      LD_ENVID_HEADER = "x-launchdarkly-env-id"
      LD_FD_FALLBACK_HEADER = "x-launchdarkly-fd-fallback"

      #
      # Requester protocol for polling data source
      #
      module Requester
        #
        # Fetches the data for the given selector.
        # Returns a Result containing a tuple of [ChangeSet, headers],
        # or an error if the data could not be retrieved.
        #
        # @param selector [LaunchDarkly::Interfaces::DataSystem::Selector, nil]
        # @return [Result]
        #
        def fetch(selector)
          raise NotImplementedError
        end
      end

      #
      # PollingDataSource is a data source that can retrieve information from
      # LaunchDarkly either as an Initializer or as a Synchronizer.
      #
      class PollingDataSource
        include LaunchDarkly::Interfaces::DataSystem::Initializer
        include LaunchDarkly::Interfaces::DataSystem::Synchronizer

        attr_reader :name

        #
        # @param poll_interval [Float] Polling interval in seconds
        # @param requester [Requester] The requester to use for fetching data
        # @param logger [Logger] The logger
        #
        def initialize(poll_interval, requester, logger)
          @requester = requester
          @poll_interval = poll_interval
          @logger = logger
          @interrupt_event = Concurrent::Event.new
          @stop = Concurrent::Event.new
          @name = "PollingDataSourceV2"
        end

        #
        # Fetch returns a Basis, or an error if the Basis could not be retrieved.
        #
        # @param ss [LaunchDarkly::Interfaces::DataSystem::SelectorStore]
        # @return [LaunchDarkly::Interfaces::DataSystem::Basis, nil]
        #
        def fetch(ss)
          poll(ss)
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
          @logger.info { "[LDClient] Starting PollingDataSourceV2 synchronizer" }
          @stop.reset
          @interrupt_event.reset

          until @stop.set?
            result = @requester.fetch(ss.selector)

            if !result.success?
              fallback = false
              envid = nil

              if result.headers
                fallback = result.headers[LD_FD_FALLBACK_HEADER] == 'true'
                envid = result.headers[LD_ENVID_HEADER]
              end

              if result.exception.is_a?(LaunchDarkly::Impl::DataSource::UnexpectedResponseError)
                error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                  LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE,
                  result.exception.status,
                  Impl::Util.http_error_message(
                    result.exception.status, "polling request", "will retry"
                  ),
                  Time.now
                )

                status_code = result.exception.status
                if Impl::Util.http_error_recoverable?(status_code)
                  yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                    state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                    error: error_info,
                    environment_id: envid,
                    revert_to_fdv1: fallback
                  )
                  # Stop polling if fallback is set; caller will handle shutdown
                  break if fallback
                  @interrupt_event.wait(@poll_interval)
                  next
                end

                yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                  state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
                  error: error_info,
                  environment_id: envid,
                  revert_to_fdv1: fallback
                )
                break
              end

              error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                LaunchDarkly::Interfaces::DataSource::ErrorInfo::NETWORK_ERROR,
                0,
                result.error,
                Time.now
              )

              yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                error: error_info,
                environment_id: envid,
                revert_to_fdv1: fallback
              )
            else
              change_set, headers = result.value
              fallback = headers[LD_FD_FALLBACK_HEADER] == 'true'
              yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
                change_set: change_set,
                environment_id: headers[LD_ENVID_HEADER],
                revert_to_fdv1: fallback
              )
            end

            break if fallback
            break if @interrupt_event.wait(@poll_interval)
          end
        end

        #
        # Stops the synchronizer.
        #
        def stop
          @logger.info { "[LDClient] Stopping PollingDataSourceV2 synchronizer" }
          @interrupt_event.set
          @stop.set
        end

        #
        # @param ss [LaunchDarkly::Interfaces::DataSystem::SelectorStore]
        # @return [LaunchDarkly::Result<LaunchDarkly::Interfaces::DataSystem::Basis, String>]
        #
        private def poll(ss)
          result = @requester.fetch(ss.selector)

          unless result.success?
            if result.exception.is_a?(LaunchDarkly::Impl::DataSource::UnexpectedResponseError)
              status_code = result.exception.status
              http_error_message_result = Impl::Util.http_error_message(
                status_code, "polling request", "will retry"
              )
              @logger.warn { "[LDClient] #{http_error_message_result}" } if Impl::Util.http_error_recoverable?(status_code)
              return LaunchDarkly::Result.fail(http_error_message_result, result.exception)
            end

            return LaunchDarkly::Result.fail(result.error || 'Failed to request payload', result.exception)
          end

          change_set, headers = result.value

          env_id = headers[LD_ENVID_HEADER]
          env_id = nil unless env_id.is_a?(String)

          basis = LaunchDarkly::Interfaces::DataSystem::Basis.new(
            change_set: change_set,
            persist: change_set.selector.defined?,
            environment_id: env_id
          )

          LaunchDarkly::Result.success(basis)
        rescue => e
          msg = "Error: Exception encountered when updating flags. #{e}"
          @logger.error { "[LDClient] #{msg}" }
          @logger.debug { "[LDClient] Exception trace: #{e.backtrace}" }
          LaunchDarkly::Result.fail(msg, e)
        end
      end

      #
      # HTTPPollingRequester is a Requester that uses HTTP to make
      # requests to the FDv2 polling endpoint.
      #
      class HTTPPollingRequester
        include Requester

        #
        # @param sdk_key [String]
        # @param config [LaunchDarkly::Config]
        #
        def initialize(sdk_key, config)
          @etag = nil
          @config = config
          @sdk_key = sdk_key
          @poll_uri = config.base_uri + FDV2_POLLING_ENDPOINT
          @http_client = Impl::Util.new_http_client(config.base_uri, config)
            .use(:auto_inflate)
            .headers("Accept-Encoding" => "gzip")
        end

        #
        # @param selector [LaunchDarkly::Interfaces::DataSystem::Selector, nil]
        # @return [Result]
        #
        def fetch(selector)
          query_params = []
          query_params << ["filter", @config.payload_filter_key] unless @config.payload_filter_key.nil?

          if selector && selector.defined?
            query_params << ["selector", selector.state]
          end

          uri = @poll_uri
          if query_params.any?
            filter_query = URI.encode_www_form(query_params)
            uri = "#{uri}?#{filter_query}"
          end

          headers = {}
          Impl::Util.default_http_headers(@sdk_key, @config).each { |k, v| headers[k] = v }
          headers["If-None-Match"] = @etag unless @etag.nil?

          begin
            response = @http_client.request("GET", uri, headers: headers)
            status = response.status.code
            response_headers = response.headers.to_h.transform_keys(&:downcase)

            if status >= 400
              return LaunchDarkly::Result.fail(
                "HTTP error #{status}",
                LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(status),
                response_headers
              )
            end

            if status == 304
              return LaunchDarkly::Result.success([LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes, response_headers])
            end

            body = response.to_s
            data = JSON.parse(body, symbolize_names: true)
            etag = response_headers["etag"]
            @etag = etag unless etag.nil?

            @config.logger.debug { "[LDClient] #{uri} response status:[#{status}] ETag:[#{etag}]" }

            changeset_result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(data)
            if changeset_result.success?
              LaunchDarkly::Result.success([changeset_result.value, response_headers])
            else
              LaunchDarkly::Result.fail(changeset_result.error, changeset_result.exception, response_headers)
            end
          rescue JSON::ParserError => e
            LaunchDarkly::Result.fail("Failed to parse JSON: #{e.message}", e, response_headers)
          rescue => e
            LaunchDarkly::Result.fail("Network error: #{e.message}", e)
          end
        end
      end

      #
      # HTTPFDv1PollingRequester is a Requester that uses HTTP to make
      # requests to the FDv1 polling endpoint.
      #
      class HTTPFDv1PollingRequester
        include Requester

        #
        # @param sdk_key [String]
        # @param config [LaunchDarkly::Config]
        #
        def initialize(sdk_key, config)
          @etag = nil
          @config = config
          @sdk_key = sdk_key
          @poll_uri = config.base_uri + FDV1_POLLING_ENDPOINT
          @http_client = Impl::Util.new_http_client(config.base_uri, config)
            .use(:auto_inflate)
            .headers("Accept-Encoding" => "gzip")
        end

        #
        # @param selector [LaunchDarkly::Interfaces::DataSystem::Selector, nil]
        # @return [Result]
        #
        def fetch(selector)
          query_params = []
          query_params << ["filter", @config.payload_filter_key] unless @config.payload_filter_key.nil?

          uri = @poll_uri
          if query_params.any?
            filter_query = URI.encode_www_form(query_params)
            uri = "#{uri}?#{filter_query}"
          end

          headers = {}
          Impl::Util.default_http_headers(@sdk_key, @config).each { |k, v| headers[k] = v }
          headers["If-None-Match"] = @etag unless @etag.nil?

          begin
            response = @http_client.request("GET", uri, headers: headers)
            status = response.status.code
            response_headers = response.headers.to_h.transform_keys(&:downcase)

            if status >= 400
              return LaunchDarkly::Result.fail(
                "HTTP error #{status}",
                LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(status),
                response_headers
              )
            end

            if status == 304
              return LaunchDarkly::Result.success([LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes, response_headers])
            end

            body = response.to_s
            data = JSON.parse(body, symbolize_names: true)
            etag = response_headers["etag"]
            @etag = etag unless etag.nil?

            @config.logger.debug { "[LDClient] #{uri} response status:[#{status}] ETag:[#{etag}]" }

            changeset_result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
            if changeset_result.success?
              LaunchDarkly::Result.success([changeset_result.value, response_headers])
            else
              LaunchDarkly::Result.fail(changeset_result.error, changeset_result.exception, response_headers)
            end
          rescue JSON::ParserError => e
            LaunchDarkly::Result.fail("Failed to parse JSON: #{e.message}", e, response_headers)
          rescue => e
            LaunchDarkly::Result.fail("Network error: #{e.message}", e)
          end
        end
      end

      #
      # Converts a polling payload into a ChangeSet.
      #
      # @param data [Hash] The polling payload
      # @return [LaunchDarkly::Result<LaunchDarkly::Interfaces::DataSystem::ChangeSet, String>] Result containing ChangeSet on success, or error message on failure
      #
      def self.polling_payload_to_changeset(data)
        unless data[:events].is_a?(Array)
          return LaunchDarkly::Result.fail("Invalid payload: 'events' key is missing or not a list")
        end

        builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new

        data[:events].each do |event|
          unless event.is_a?(Hash)
            return LaunchDarkly::Result.fail("Invalid payload: 'events' must be a list of objects")
          end

          next unless event[:event]

          case event[:event]
          when LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT
            begin
              server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.from_h(event[:data])
            rescue ArgumentError => e
              return LaunchDarkly::Result.fail("Invalid JSON in server intent", e)
            end

            if server_intent.payload.code == LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE
              return LaunchDarkly::Result.success(LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes)
            end

            builder.start(server_intent.payload.code)

          when LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT
            begin
              put = LaunchDarkly::Impl::DataSystem::ProtocolV2::PutObject.from_h(event[:data])
            rescue ArgumentError => e
              return LaunchDarkly::Result.fail("Invalid JSON in put object", e)
            end

            builder.add_put(put.kind, put.key, put.version, put.object)

          when LaunchDarkly::Interfaces::DataSystem::EventName::DELETE_OBJECT
            begin
              delete_object = LaunchDarkly::Impl::DataSystem::ProtocolV2::DeleteObject.from_h(event[:data])
            rescue ArgumentError => e
              return LaunchDarkly::Result.fail("Invalid JSON in delete object", e)
            end

            builder.add_delete(delete_object.kind, delete_object.key, delete_object.version)

          when LaunchDarkly::Interfaces::DataSystem::EventName::PAYLOAD_TRANSFERRED
            begin
              selector = LaunchDarkly::Interfaces::DataSystem::Selector.from_h(event[:data])
              changeset = builder.finish(selector)
              return LaunchDarkly::Result.success(changeset)
            rescue ArgumentError, RuntimeError => e
              return LaunchDarkly::Result.fail("Invalid JSON in payload transferred object", e)
            end
          end
        end

        LaunchDarkly::Result.fail("didn't receive any known protocol events in polling payload")
      end

      #
      # Converts an FDv1 polling payload into a ChangeSet.
      #
      # @param data [Hash] The FDv1 polling payload
      # @return [LaunchDarkly::Result<LaunchDarkly::Interfaces::DataSystem::ChangeSet, String>] Result containing ChangeSet on success, or error message on failure
      #
      def self.fdv1_polling_payload_to_changeset(data)
        builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
        builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
        selector = LaunchDarkly::Interfaces::DataSystem::Selector.no_selector

        kind_mappings = [
          [LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG, :flags],
          [LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT, :segments],
        ]

        kind_mappings.each do |kind, fdv1_key|
          kind_data = data[fdv1_key]
          next if kind_data.nil?

          unless kind_data.is_a?(Hash)
            return LaunchDarkly::Result.fail("Invalid format: #{fdv1_key} is not an object")
          end

          kind_data.each do |key, flag_or_segment|
            unless flag_or_segment.is_a?(Hash)
              return LaunchDarkly::Result.fail("Invalid format: #{key} is not an object")
            end

            version = flag_or_segment[:version]
            return LaunchDarkly::Result.fail("Invalid format: #{key} does not have a version set") if version.nil?

            builder.add_put(kind, key.to_s, version, flag_or_segment)
          end
        end

        LaunchDarkly::Result.success(builder.finish(selector))
      end

      #
      # Builder for a PollingDataSource.
      #
      class PollingDataSourceBuilder
        #
        # @param sdk_key [String]
        # @param config [LaunchDarkly::Config]
        #
        def initialize(sdk_key, config)
          @sdk_key = sdk_key
          @config = config
          @requester = nil
        end

        #
        # Sets a custom Requester for the PollingDataSource.
        #
        # @param requester [Requester]
        # @return [PollingDataSourceBuilder]
        #
        def requester(requester)
          @requester = requester
          self
        end

        #
        # Builds the PollingDataSource with the configured parameters.
        #
        # @return [PollingDataSource]
        #
        def build
          requester = @requester || HTTPPollingRequester.new(@sdk_key, @config)
          PollingDataSource.new(@config.poll_interval, requester, @config.logger)
        end
      end

      #
      # Builder for an FDv1 PollingDataSource.
      #
      class FDv1PollingDataSourceBuilder
        #
        # @param sdk_key [String]
        # @param config [LaunchDarkly::Config]
        #
        def initialize(sdk_key, config)
          @sdk_key = sdk_key
          @config = config
          @requester = nil
        end

        #
        # Sets a custom Requester for the PollingDataSource.
        #
        # @param requester [Requester]
        # @return [FDv1PollingDataSourceBuilder]
        #
        def requester(requester)
          @requester = requester
          self
        end

        #
        # Builds the PollingDataSource with the configured parameters.
        #
        # @return [PollingDataSource]
        #
        def build
          requester = @requester || HTTPFDv1PollingRequester.new(@sdk_key, @config)
          PollingDataSource.new(@config.poll_interval, requester, @config.logger)
        end
      end
    end
  end
end
