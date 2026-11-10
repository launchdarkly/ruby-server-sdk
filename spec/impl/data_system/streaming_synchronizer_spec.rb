# frozen_string_literal: true

require "spec_helper"
require "http_util"
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
          let(:synchronizer) { LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new.build(sdk_key, config) }
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
            expect(update.fallback_to_fdv1).to eq(false)
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
            expect(update.fallback_to_fdv1).to eq(false)
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
            expect(update.fallback_to_fdv1).to eq(false)
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
            expect(update.fallback_to_fdv1).to eq(false)
            expect(update.environment_id).to be_nil
            expect(update.change_set).not_to be_nil
            expect(update.change_set.changes.length).to eq(1)
            expect(update.change_set.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE)
            expect(update.change_set.changes[0].kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG)
            expect(update.change_set.changes[0].key).to eq(:flagkey)
            expect(update.change_set.changes[0].version).to eq(101)
          end

          it "ignores put and delete objects of unknown kinds" do
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
              payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                id: "id",
                target: 300,
                code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                reason: "cant-catchup"
              )
            )
            known_put = LaunchDarkly::Impl::DataSystem::ProtocolV2::PutObject.new(
              version: 100,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: "flagkey",
              object: { key: "flagkey" }
            )
            unknown_put = LaunchDarkly::Impl::DataSystem::ProtocolV2::PutObject.new(
              version: 100,
              kind: "some-future-kind",
              key: "otherkey",
              object: { foo: 1 }
            )
            unknown_delete = LaunchDarkly::Impl::DataSystem::ProtocolV2::DeleteObject.new(
              version: 101,
              kind: "some-future-kind",
              key: "otherkey"
            )
            known_delete = LaunchDarkly::Impl::DataSystem::ProtocolV2::DeleteObject.new(
              version: 101,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT,
              key: "segmentkey"
            )
            selector = LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300)

            expect(logger).not_to receive(:warn)
            expect(logger).not_to receive(:error)

            # Process a payload that mixes known and unknown object kinds
            synchronizer.send(:process_message, MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT, JSON.generate(server_intent.to_h)),
change_set_builder, envid)
            [known_put, unknown_put].each do |put|
              result = synchronizer.send(:process_message, MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT, JSON.generate(put.to_h)),
change_set_builder, envid)
              expect(result).to be_nil
            end
            [unknown_delete, known_delete].each do |delete_object|
              result = synchronizer.send(:process_message, MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::DELETE_OBJECT, JSON.generate(delete_object.to_h)),
change_set_builder, envid)
              expect(result).to be_nil
            end
            update = synchronizer.send(:process_message, MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::PAYLOAD_TRANSFERRED, JSON.generate(selector.to_h)),
change_set_builder, envid)

            # The payload completes as valid with only the known objects
            expect(update).not_to be_nil
            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.error).to be_nil
            expect(update.change_set).not_to be_nil
            expect(update.change_set.changes.length).to eq(2)
            expect(update.change_set.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT)
            expect(update.change_set.changes[0].kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG)
            expect(update.change_set.changes[0].key).to eq(:flagkey)
            expect(update.change_set.changes[1].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE)
            expect(update.change_set.changes[1].kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT)
            expect(update.change_set.changes[1].key).to eq(:segmentkey)
          end

          it "rejects put and delete objects whose data is not an object" do
            [
              LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT,
              LaunchDarkly::Interfaces::DataSystem::EventName::DELETE_OBJECT,
            ].each do |event_name|
              ['"x"', "[]", "null", "5"].each do |data|
                expect {
                  synchronizer.send(:process_message, MockSSEEvent.new(event_name, data), change_set_builder, envid)
                }.to raise_error(ArgumentError, "#{event_name} data must be an object")
              end
            end
          end

          it "rejects put and delete objects whose kind is not a string" do
            [
              LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT,
              LaunchDarkly::Interfaces::DataSystem::EventName::DELETE_OBJECT,
            ].each do |event_name|
              object_field = event_name == LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT ? ',"object":{}' : ""
              ["", '"kind":null,', '"kind":5,', '"kind":["flag"],'].each do |kind_field|
                data = '{' + kind_field + '"key":"flagkey","version":100' + object_field + '}'
                expect {
                  synchronizer.send(:process_message, MockSSEEvent.new(event_name, data), change_set_builder, envid)
                }.to raise_error(ArgumentError, "#{event_name} kind must be a string")
              end
            end
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
              reason: "test reason"
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

          it "stamps fallback_to_fdv1 on a TRANSFER_NONE update when the directive is pending" do
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

            update = synchronizer.send(:process_message, event, change_set_builder, envid, fdv1_fallback_pending: true)

            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.fallback_to_fdv1).to eq(true)
          end

          it "stamps fallback_to_fdv1 on a PAYLOAD_TRANSFERRED update when the directive is pending" do
            server_intent = LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
              payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                id: "id",
                target: 300,
                code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                reason: "cant-catchup"
              )
            )
            selector = LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300)

            synchronizer.send(:process_message, MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT,
              JSON.generate(server_intent.to_h)
            ), change_set_builder, envid)
            update = synchronizer.send(:process_message, MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::PAYLOAD_TRANSFERRED,
              JSON.generate(selector.to_h)
            ), change_set_builder, envid, fdv1_fallback_pending: true)

            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(update.fallback_to_fdv1).to eq(true)
            expect(update.change_set).not_to be_nil
          end

          it "does not stamp fallback_to_fdv1 on intermediate (non-payload-completing) events" do
            # The directive is only meaningful once it can ride along on a Valid result that
            # the consumer can act on. PUT_OBJECT, DELETE_OBJECT, GOODBYE, ERROR don't
            # produce Updates -- intermediate events return nil even when the directive is
            # pending. The signal arrives with the next payload-completing event.
            put = LaunchDarkly::Impl::DataSystem::ProtocolV2::PutObject.new(
              version: 100,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: "flagkey",
              object: { key: "flagkey" }
            )
            event = MockSSEEvent.new(
              LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT,
              JSON.generate(put.to_h)
            )

            update = synchronizer.send(:process_message, event, change_set_builder, envid, fdv1_fallback_pending: true)

            expect(update).to be_nil
          end
        end

        describe '#handle_error' do
          let(:synchronizer) { LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new.build(sdk_key, config) }

          it "reports a server-initiated stream close as a network error" do
            expect(logger).to receive(:warn)

            update = synchronizer.send(:handle_error, SSE::Errors::StreamClosedByServerError.new, "env-abc", false)

            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(update.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::NETWORK_ERROR)
            expect(update.environment_id).to eq("env-abc")
          end

          it "reports invalid JSON as invalid data" do
            expect(logger).to receive(:error)

            update = synchronizer.send(:handle_error, JSON::ParserError.new("bad"), "env-abc", false)

            expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(update.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA)
            expect(update.environment_id).to eq("env-abc")
          end

          it "reports one invalid data status for an invalid stream event" do
            transfer_none = "event: server-intent\ndata: " + JSON.generate(
              LaunchDarkly::Interfaces::DataSystem::ServerIntent.new(
                payload: LaunchDarkly::Interfaces::DataSystem::Payload.new(
                  id: "id", target: 1, code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE, reason: "up-to-date"
                )
              ).to_h
            ) + "\n\n"
            request_count = 0
            with_server do |server|
              server.setup_response(FDV2_STREAMING_ENDPOINT) do |_req, res|
                request_count += 1
                res.status = 200
                res.content_type = "text/event-stream"
                res.body = request_count == 1 ? "event: server-intent\ndata: {not json\n\n" : transfer_none
              end

              stream = LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new
                .base_uri(server.base_uri.to_s)
                .initial_reconnect_delay(0.01)
                .build(sdk_key, LaunchDarkly::Config.new(logger: $null_log))
              updates = Queue.new
              thread = Thread.new { stream.sync(Struct.new(:selector).new(nil)) { |update| updates << update } }
              begin
                received = []
                while (update = updates.pop(timeout: 5))
                  received << update
                  break if update.state == LaunchDarkly::Interfaces::DataSource::Status::VALID
                end
              ensure
                stream.stop
                thread.join(5)
              end

              expected_states = [
                LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                LaunchDarkly::Interfaces::DataSource::Status::VALID,
              ]
              expect(received.map(&:state)).to eq(expected_states)
              expect(received.first.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA)
            end
          end
        end

        describe '#sync' do
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

          def build_synchronizer(base_uri)
            LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new
              .base_uri(base_uri.to_s)
              .initial_reconnect_delay(0.01)
              .build(sdk_key, config)
          end

          # Runs sync in a thread. Yields a queue that receives each update, and the sync thread.
          def with_sync(synchronizer)
            updates = Queue.new
            thread = Thread.new { synchronizer.sync(selector_store) { |update| updates << update } }
            begin
              yield updates, thread
            ensure
              synchronizer.stop
              thread.join(5)
            end
          end

          # Replaces the SSE client with a double. Yields the handlers that sync registers on it.
          def with_handlers(synchronizer)
            handlers = {}
            registered = Queue.new
            connection = double("connection")
            %i[on_connect on_event on_error query_params].each do |name|
              allow(connection).to receive(name) { |&block| handlers[name] = block }
            end
            allow(SSE::Client).to receive(:new) do |_uri, **_opts, &block|
              block.call(connection)
              registered << true
              double("SSE::Client", close: nil)
            end

            with_sync(synchronizer) do |updates, thread|
              expect(registered.pop(timeout: 5)).to be true
              yield handlers, updates, thread
            end
          end

          it "reports invalid data as INTERRUPTED and restarts the stream" do
            request_count = 0
            with_server do |server|
              server.setup_response(FDV2_STREAMING_ENDPOINT) do |_req, res|
                request_count += 1
                res.status = 200
                res.content_type = "text/event-stream"
                res.body = request_count == 1 ? "event: server-intent\ndata: {not json\n\n" : transfer_none_event
              end

              with_sync(build_synchronizer(server.base_uri)) do |updates|
                first = updates.pop(timeout: 5)
                expect(first.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
                expect(first.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA)

                valid = nil
                while (update = updates.pop(timeout: 5))
                  if update.state == LaunchDarkly::Interfaces::DataSource::Status::VALID
                    valid = update
                    break
                  end
                end
                expect(valid).not_to be_nil
                expect(request_count).to be >= 2
              end
            end
          end

          it "raises the parse error to the SSE client so that it restarts the stream" do
            with_handlers(build_synchronizer("http://stream.example.com")) do |handlers, updates|
              event = MockSSEEvent.new(LaunchDarkly::Interfaces::DataSystem::EventName::SERVER_INTENT, "{not json")

              expect { handlers[:on_event].call(event) }.to raise_error(JSON::ParserError)
              expect(updates.pop(timeout: 1).error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA)
            end
          end

          [401, 403].each do |status|
            it "reports OFF and stops after unrecoverable error #{status}" do
              with_server do |server|
                server.setup_status_response(FDV2_STREAMING_ENDPOINT, status)

                with_sync(build_synchronizer(server.base_uri)) do |updates, thread|
                  update = updates.pop(timeout: 5)
                  expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::OFF)
                  expect(update.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE)
                  expect(update.error.status_code).to eq(status)

                  expect(thread.join(5)).not_to be_nil
                  expect(updates).to be_empty
                  expect(server.requests.length).to eq(1)
                end
              end
            end
          end

          it "reports INTERRUPTED and keeps the stream open after recoverable error 503" do
            with_handlers(build_synchronizer("http://stream.example.com")) do |handlers, updates, thread|
              handlers[:on_error].call(SSE::Errors::HTTPStatusError.new(503, ""))

              update = updates.pop(timeout: 1)
              expect(update.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
              expect(update.error.status_code).to eq(503)
              expect(thread.join(0.1)).to be_nil
            end
          end

          it "yields nothing after it is stopped" do
            synchronizer = build_synchronizer("http://stream.example.com")
            with_handlers(synchronizer) do |handlers, updates, thread|
              synchronizer.stop
              expect(thread.join(5)).not_to be_nil

              handlers[:on_error].call(SSE::Errors::HTTPStatusError.new(503, ""))
              handlers[:on_error].call(SSE::Errors::StreamClosedByServerError.new)

              expect(updates).to be_empty
            end
          end
        end

        describe 'SSE client options' do
          let(:config) { LaunchDarkly::Config.new(logger: $null_log) }

          def captured_sse_options(synchronizer)
            captured = nil
            allow(SSE::Client).to receive(:new) do |_uri, **opts|
              captured = opts
              double("SSE::Client", close: nil)
            end

            # Stop first so that sync returns as soon as it creates the client.
            synchronizer.stop
            synchronizer.sync(double("SelectorStore"))
            captured
          end

          it "passes the default connect timeout" do
            synchronizer = LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new.build(sdk_key, config)
            opts = captured_sse_options(synchronizer)
            expect(opts[:connect_timeout]).to eq(HttpConfigOptions::DEFAULT_CONNECT_TIMEOUT)
          end

          it "passes a configured connect timeout" do
            synchronizer = LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new.connect_timeout(0.5).build(sdk_key, config)
            opts = captured_sse_options(synchronizer)
            expect(opts[:connect_timeout]).to eq(0.5)
          end

          it "passes the configured client options" do
            socket_factory = Object.new
            synchronizer = LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new
              .socket_factory(socket_factory)
              .initial_reconnect_delay(3)
              .build(sdk_key, config)
            opts = captured_sse_options(synchronizer)
            expect(opts).to eq(
              headers: Impl::Util.default_http_headers(sdk_key, config),
              read_timeout: STREAM_READ_TIMEOUT,
              connect_timeout: HttpConfigOptions::DEFAULT_CONNECT_TIMEOUT,
              logger: $null_log,
              socket_factory: socket_factory,
              reconnect_time: 3
            )
          end

          it "abandons a connect attempt after the connect timeout" do
            socket_factory = HangingSocketFactory.new
            synchronizer = LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new
              .base_uri("http://stream.example.com")
              .connect_timeout(0.2)
              .socket_factory(socket_factory)
              .build(sdk_key, config)
            selector_store = Struct.new(:selector).new(nil)

            sync_thread = Thread.new { synchronizer.sync(selector_store) { |_update| } }
            begin
              # Without the connect timeout, the attempt blocks for the SSE client default of 10 seconds.
              blocked = socket_factory.first_blocked_duration(3)
              expect(blocked).not_to be_nil
              expect(blocked).to be < 1
            ensure
              synchronizer.stop
              sync_thread.join(5)
            end
          end
        end

        describe 'diagnostic event recording' do
          let(:synchronizer) { LaunchDarkly::DataSystem::StreamingDataSourceBuilder.new.build(sdk_key, config) }

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

          it "measures duration on the monotonic clock, unaffected by wall-clock steps" do
            diagnostic_accumulator = double("DiagnosticAccumulator")

            synchronizer.set_diagnostic_accumulator(diagnostic_accumulator)

            expect(diagnostic_accumulator).to receive(:record_stream_init) do |_timestamp, _failed, duration|
              # A backward wall-clock step used to produce a negative duration here.
              expect(duration).to be >= 0
              expect(duration).to be < 1000
            end

            synchronizer.send(:log_connection_started)
            Timecop.freeze(Time.now - 120) do
              synchronizer.send(:log_connection_result, true)
            end
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
        end
      end
    end
  end
end
