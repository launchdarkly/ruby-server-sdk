# frozen_string_literal: true

require "spec_helper"
require "ldclient-rb/impl/data_system/streaming"
require "ldclient-rb/interfaces"
require "json"

module LaunchDarkly
  module Impl
    module DataSystem
      RSpec.describe StreamingDataSource do
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

        # Mock SSE event
        class MockSSEEvent
          attr_reader :type, :data

          def initialize(type, data = nil)
            @type = type
            @data = data
          end
        end

        describe '#process_message' do
          let(:synchronizer) { StreamingDataSource.new(sdk_key, config) }
          let(:change_set_builder) { LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new }
          let(:envid) { nil }

          it "ignores unknown events" do
            event = MockSSEEvent.new(:unknown_type, "{}")
            update = synchronizer.send(:process_message, event, change_set_builder, envid)
            expect(update).to be_nil
          end

          it "ignores heartbeat events" do
            event = MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::HEARTBEAT)
            update = synchronizer.send(:process_message, event, change_set_builder, envid)
            expect(update).to be_nil
          end

          it "handles no changes (TRANSFER_NONE)" do
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
              payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                id: "id",
                target: 300,
                code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE,
                reason: "up-to-date"
              )
            )

            event = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT,
              JSON.generate(server_intent.to_h)
            )

            update = synchronizer.send(:process_message, event, change_set_builder, envid)
            expect(update).not_to be_nil
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.error).to be_nil
            expect(update.revert_to_fdv1).to eq(false)
            expect(update.environment_id).to be_nil
            expect(update.change_set).to be_nil
          end

          it "handles empty changeset" do
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
              payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                id: "id",
                target: 300,
                code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                reason: "cant-catchup"
              )
            )
            selector = LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300)

            # Process server intent
            event1 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT,
              JSON.generate(server_intent.to_h)
            )
            synchronizer.send(:process_message, event1, change_set_builder, envid)

            # Process payload transferred
            event2 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::PAYLOAD_TRANSFERRED,
              JSON.generate(selector.to_h)
            )
            update = synchronizer.send(:process_message, event2, change_set_builder, envid)

            expect(update).not_to be_nil
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.error).to be_nil
            expect(update.revert_to_fdv1).to eq(false)
            expect(update.environment_id).to be_nil
            expect(update.change_set).not_to be_nil
            expect(update.change_set.changes.length).to eq(0)
            expect(update.change_set.selector).not_to be_nil
            expect(update.change_set.selector.version).to eq(300)
            expect(update.change_set.selector.state).to eq("p:SOMETHING:300")
            expect(update.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
          end

          it "handles put objects" do
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
              payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                id: "id",
                target: 300,
                code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                reason: "cant-catchup"
              )
            )
            put = LaunchDarkly::Impl::DataSystem::ProtocolV2::PutObject.new(
              version: 100,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: "flagkey",
              object: { key: "flagkey" }
            )
            selector = LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300)

            # Process server intent
            event1 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT,
              JSON.generate(server_intent.to_h)
            )
            synchronizer.send(:process_message, event1, change_set_builder, envid)

            # Process put
            event2 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT,
              JSON.generate(put.to_h)
            )
            synchronizer.send(:process_message, event2, change_set_builder, envid)

            # Process payload transferred
            event3 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::PAYLOAD_TRANSFERRED,
              JSON.generate(selector.to_h)
            )
            update = synchronizer.send(:process_message, event3, change_set_builder, envid)

            expect(update).not_to be_nil
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.error).to be_nil
            expect(update.revert_to_fdv1).to eq(false)
            expect(update.environment_id).to be_nil
            expect(update.change_set).not_to be_nil
            expect(update.change_set.changes.length).to eq(1)
            expect(update.change_set.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT)
            expect(update.change_set.changes[0].kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG)
            expect(update.change_set.changes[0].key).to eq(:flagkey)
            expect(update.change_set.changes[0].object).to eq({ key: "flagkey" })
            expect(update.change_set.changes[0].version).to eq(100)
          end

          it "handles delete objects" do
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
              payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                id: "id",
                target: 300,
                code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                reason: "cant-catchup"
              )
            )
            delete_object = LaunchDarkly::Impl::DataSystem::ProtocolV2::DeleteObject.new(
              version: 101,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: "flagkey"
            )
            selector = LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300)

            # Process server intent
            event1 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT,
              JSON.generate(server_intent.to_h)
            )
            synchronizer.send(:process_message, event1, change_set_builder, envid)

            # Process delete
            event2 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::DELETE_OBJECT,
              JSON.generate(delete_object.to_h)
            )
            synchronizer.send(:process_message, event2, change_set_builder, envid)

            # Process payload transferred
            event3 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::PAYLOAD_TRANSFERRED,
              JSON.generate(selector.to_h)
            )
            update = synchronizer.send(:process_message, event3, change_set_builder, envid)

            expect(update).not_to be_nil
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.error).to be_nil
            expect(update.revert_to_fdv1).to eq(false)
            expect(update.environment_id).to be_nil
            expect(update.change_set).not_to be_nil
            expect(update.change_set.changes.length).to eq(1)
            expect(update.change_set.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE)
            expect(update.change_set.changes[0].kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG)
            expect(update.change_set.changes[0].key).to eq(:flagkey)
            expect(update.change_set.changes[0].version).to eq(101)
          end

          it "swallows goodbye events" do
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
              payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                id: "id",
                target: 300,
                code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                reason: "cant-catchup"
              )
            )
            goodbye = LaunchDarkly::Impl::DataSystem::ProtocolV2::Goodbye.new(
              reason: "test reason",
              silent: true,
              catastrophe: false
            )
            selector = LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300)

            # Process server intent
            event1 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT,
              JSON.generate(server_intent.to_h)
            )
            synchronizer.send(:process_message, event1, change_set_builder, envid)

            # Process goodbye (should be ignored)
            event2 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::GOODBYE,
              JSON.generate(goodbye.to_h)
            )
            result = synchronizer.send(:process_message, event2, change_set_builder, envid)
            expect(result).to be_nil

            # Process payload transferred
            event3 = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::PAYLOAD_TRANSFERRED,
              JSON.generate(selector.to_h)
            )
            update = synchronizer.send(:process_message, event3, change_set_builder, envid)

            expect(update).not_to be_nil
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.change_set).not_to be_nil
            expect(update.change_set.changes.length).to eq(0)
          end

          it "error event resets changeset builder" do
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
              payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                id: "id",
                target: 300,
                code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                reason: "cant-catchup"
              )
            )
            put = LaunchDarkly::Impl::DataSystem::ProtocolV2::PutObject.new(
              version: 100,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: "flagkey",
              object: { key: "flagkey" }
            )
            error = LaunchDarkly::Impl::DataSystem::ProtocolV2::Error.new(
              payload_id: "p:SOMETHING:300",
              reason: "test reason"
            )
            delete_object = LaunchDarkly::Impl::DataSystem::ProtocolV2::DeleteObject.new(
              version: 101,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: "flagkey"
            )
            selector = LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300)

            # Process server intent
            synchronizer.send(:process_message, MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT, JSON.generate(server_intent.to_h)),
change_set_builder, envid)

            # Process put (should be reset by error)
            synchronizer.send(:process_message, MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT, JSON.generate(put.to_h)), change_set_builder, envid)

            # Process error (resets builder)
            synchronizer.send(:process_message, MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::ERROR, JSON.generate(error.to_h)), change_set_builder, envid)

            # Process delete (after reset)
            synchronizer.send(:process_message, MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::DELETE_OBJECT, JSON.generate(delete_object.to_h)),
change_set_builder, envid)

            # Process payload transferred
            update = synchronizer.send(:process_message, MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::PAYLOAD_TRANSFERRED, JSON.generate(selector.to_h)),
change_set_builder, envid)

            expect(update).not_to be_nil
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.change_set).not_to be_nil
            # Only delete should be in the changeset (put was reset by error)
            expect(update.change_set.changes.length).to eq(1)
            expect(update.change_set.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE)
          end
        end

        describe 'diagnostic event recording' do
          let(:synchronizer) { StreamingDataSource.new(sdk_key, config) }

          it "logs successful connection when diagnostic_accumulator is provided" do
            diagnostic_accumulator = double("DiagnosticAccumulator")
            expect(diagnostic_accumulator).to receive(:record_stream_init).with(
              kind_of(Integer),
              false,
              kind_of(Integer)
            )

            synchronizer.set_diagnostic_accumulator(diagnostic_accumulator)
            synchronizer.send(:log_connection_started)
            synchronizer.send(:log_connection_result, true)
          end

          it "logs failed connection when diagnostic_accumulator is provided" do
            diagnostic_accumulator = double("DiagnosticAccumulator")
            expect(diagnostic_accumulator).to receive(:record_stream_init).with(
              kind_of(Integer),
              true,
              kind_of(Integer)
            )

            synchronizer.set_diagnostic_accumulator(diagnostic_accumulator)
            synchronizer.send(:log_connection_started)
            synchronizer.send(:log_connection_result, false)
          end

          it "logs connection metrics with correct timestamp and duration" do
            diagnostic_accumulator = double("DiagnosticAccumulator")

            synchronizer.set_diagnostic_accumulator(diagnostic_accumulator)

            expect(diagnostic_accumulator).to receive(:record_stream_init) do |timestamp, failed, duration|
              expect(timestamp).to be_a(Integer)
              expect(timestamp).to be > 0
              expect(failed).to eq(false)
              expect(duration).to be_a(Integer)
              expect(duration).to be >= 0
            end

            synchronizer.send(:log_connection_started)
            sleep(0.01) # Small delay to ensure measurable duration
            synchronizer.send(:log_connection_result, true)
          end

          it "only logs once per connection attempt" do
            diagnostic_accumulator = double("DiagnosticAccumulator")
            expect(diagnostic_accumulator).to receive(:record_stream_init).once

            synchronizer.set_diagnostic_accumulator(diagnostic_accumulator)
            synchronizer.send(:log_connection_started)
            synchronizer.send(:log_connection_result, true)

            # Second call should not record again (no new connection_started)
            synchronizer.send(:log_connection_result, true)
          end

          it "does not log when diagnostic_accumulator is not set" do
            # Should not raise an error
            expect { synchronizer.send(:log_connection_started) }.not_to raise_error
            expect { synchronizer.send(:log_connection_result, true) }.not_to raise_error
          end

          it "does not log when connection was not started" do
            diagnostic_accumulator = double("DiagnosticAccumulator")
            expect(diagnostic_accumulator).not_to receive(:record_stream_init)

            synchronizer.set_diagnostic_accumulator(diagnostic_accumulator)
            # Call log_connection_result without log_connection_started
            synchronizer.send(:log_connection_result, true)
          end

          it "resets connection attempt time after logging" do
            diagnostic_accumulator = double("DiagnosticAccumulator")
            expect(diagnostic_accumulator).to receive(:record_stream_init).once

            synchronizer.set_diagnostic_accumulator(diagnostic_accumulator)
            synchronizer.send(:log_connection_started)
            synchronizer.send(:log_connection_result, true)

            # Another log_connection_result should not record (time was reset)
            synchronizer.send(:log_connection_result, true)
          end
        end
      end
    end
  end
end
