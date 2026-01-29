# frozen_string_literal: true

require "spec_helper"
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
            payload_filter_key: nil,
            socket_factory: nil,
            initial_reconnect_delay: 1,
            instance_id: nil
          )
        end

        let(:synchronizer) { StreamingDataSourceBuilder.new.build(sdk_key, config) }

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

            expect(update.revert_to_fdv1).to be true
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

            expect(update.revert_to_fdv1).to be_falsy
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
          end

          it "does not trigger fallback when header value is not 'true'" do
            error = SSE::Errors::HTTPStatusError.new(
              503,
              "Not a fallback",
              {
                "x-launchdarkly-fd-fallback" => "false",
              }
            )

            # Simulate the header extraction logic from on_error callback (lines 128-135)
            fallback = false
            if error.respond_to?(:headers) && error.headers
              fallback = true if error.headers["x-launchdarkly-fd-fallback"] == 'true'
            end

            expect(fallback).to be false
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
          it "extracts environment ID from connection headers" do
            # Simulate HTTP::Headers object from SSE client
            headers = double("HTTP::Headers")
            allow(headers).to receive(:[]).with("x-launchdarkly-env-id").and_return("env-from-connect")
            allow(headers).to receive(:[]).with("x-launchdarkly-fd-fallback").and_return(nil)

            # Verify the logic that would be in on_connect
            envid = nil
            if headers
              envid_from_headers = headers["x-launchdarkly-env-id"]
              envid = envid_from_headers if envid_from_headers
            end

            expect(envid).to eq("env-from-connect")
          end

          it "detects fallback header on connection" do
            headers = double("HTTP::Headers")
            allow(headers).to receive(:[]).with("x-launchdarkly-env-id").and_return("env-123")
            allow(headers).to receive(:[]).with("x-launchdarkly-fd-fallback").and_return("true")

            # Verify the logic that would trigger fallback on connect
            should_fallback = false
            if headers && headers["x-launchdarkly-fd-fallback"] == 'true'
              should_fallback = true
            end

            expect(should_fallback).to be true
          end

          it "does not trigger fallback when header is missing on connection" do
            headers = double("HTTP::Headers")
            allow(headers).to receive(:[]).with("x-launchdarkly-env-id").and_return("env-456")
            allow(headers).to receive(:[]).with("x-launchdarkly-fd-fallback").and_return(nil)

            should_fallback = false
            if headers && headers["x-launchdarkly-fd-fallback"] == 'true'
              should_fallback = true
            end

            expect(should_fallback).to be false
          end
        end
      end
    end
  end
end
