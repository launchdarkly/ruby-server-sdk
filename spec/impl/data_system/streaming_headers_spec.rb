# frozen_string_literal: true

require "spec_helper"
require "http_util"
require "json"
require "ldclient-rb/impl/data_system/streaming"
require "ldclient-rb/interfaces"

module LaunchDarkly
  module Impl
    module DataSystem
      RSpec.describe "StreamingDataSource FDv1 fallback header detection" do
        let(:logger) { double("Logger", info: nil, warn: nil, error: nil, debug: nil) }
        let(:sdk_key) { "test-sdk-key" }
        let(:config) do
          double(
            "Config",
            logger: logger,
            stream_uri: "https://stream.example.com",
            socket_factory: nil,
            initial_reconnect_delay: 1,
            instance_id: nil
          )
        end

        let(:synchronizer) { LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new.build(sdk_key, config) }

        describe "on_error callback" do
          it "triggers FDv1 fallback when X-LD-FD-FALLBACK header is true" do
            error_with_fallback = SSE::Errors::HTTPStatusError.new(
              503,
              "Service Unavailable",
              {
                "x-launchdarkly-fd-fallback" => "true",
                "x-launchdarkly-env-id" => "test-env-123",
              }
            )

            update = synchronizer.send(:handle_error, error_with_fallback, "test-env-123", true)

            expect(update.fallback_to_fdv1).to be true
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::OFF)
            expect(update.environment_id).to eq("test-env-123")
          end

          it "does not trigger fallback when header is absent" do
            error_without_fallback = SSE::Errors::HTTPStatusError.new(
              503,
              "Service Unavailable",
              {
                "x-launchdarkly-env-id" => "test-env-456",
              }
            )

            update = synchronizer.send(:handle_error, error_without_fallback, "test-env-456", false)

            expect(update.fallback_to_fdv1).to be_falsy
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
          end

          it "does not trigger fallback when header value is not 'true'" do
            with_server do |server|
              server.setup_status_response(FDV2_STREAMING_ENDPOINT, 503, { "X-LD-FD-Fallback" => "false" })
              synchronizer = LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new
                .base_uri(server.base_uri.to_s)
                .build(sdk_key, LaunchDarkly::Config.new(logger: $null_log))
              updates = Queue.new
              thread = Thread.new { synchronizer.sync(Struct.new(:selector).new(nil)) { |update| updates << update } }
              begin
                update = updates.pop(timeout: 5)
              ensure
                synchronizer.stop
                thread.join(5)
              end

              expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
              expect(update.fallback_to_fdv1).to be_falsy
            end
          end

          it "handles errors without headers gracefully" do
            # Old version of ld-eventsource gem might not have headers
            error_no_headers = SSE::Errors::HTTPStatusError.new(500, "Internal Server Error")

            expect(error_no_headers.headers).to be_nil

            update = synchronizer.send(:handle_error, error_no_headers, nil, false)
            expect(update).not_to be_nil
          end
        end

        describe "on_connect callback" do
          let(:config) { LaunchDarkly::Config.new(logger: $null_log) }
          let(:selector_store) { Struct.new(:selector).new(nil) }
          let(:transfer_none_event) do
            intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
              payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                id: "id",
                target: 1,
                code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE,
                reason: "up-to-date"
              )
            )
            "event: server-intent\ndata: #{JSON.generate(intent.to_h)}\n\n"
          end

          # Serves one server-intent event with the given response headers. Returns the first update.
          def first_update_with_headers(headers)
            with_server do |server|
              server.setup_ok_response(FDV2_STREAMING_ENDPOINT, transfer_none_event, "text/event-stream", headers)
              synchronizer = LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new
                .base_uri(server.base_uri.to_s)
                .build(sdk_key, config)
              updates = Queue.new
              thread = Thread.new { synchronizer.sync(selector_store) { |update| updates << update } }
              begin
                updates.pop(timeout: 5)
              ensure
                synchronizer.stop
                thread.join(5)
              end
            end
          end

          it "extracts environment ID from connection headers" do
            update = first_update_with_headers({ "X-LD-EnvID" => "env-from-connect" })

            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.environment_id).to eq("env-from-connect")
          end

          it "has no environment ID when the header is missing" do
            update = first_update_with_headers({})

            expect(update.environment_id).to be_nil
          end

          it "detects fallback header on connection" do
            update = first_update_with_headers({ "X-LD-EnvID" => "env-123", "X-LD-FD-Fallback" => "true" })

            expect(update.fallback_to_fdv1).to be true
            expect(update.environment_id).to eq("env-123")
          end

          it "does not trigger fallback when header is missing on connection" do
            update = first_update_with_headers({ "X-LD-EnvID" => "env-456" })

            expect(update.fallback_to_fdv1).to be false
          end
        end
      end
    end
  end
end
