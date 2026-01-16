# frozen_string_literal: true

require "spec_helper"
require "ldclient-rb/impl/data_system/polling"
require "ldclient-rb/interfaces"

module LaunchDarkly
  module Impl
    module DataSystem
      RSpec.describe PollingDataSource do
        let(:logger) { double("Logger", info: nil, warn: nil, error: nil, debug: nil) }

        class ListBasedRequester
          include Requester

          def initialize(results)
            @results = results
            @index = 0
          end

          def fetch(selector)
            @results[@index].tap { @index += 1 }
          end
        end

        class RequesterWithCleanup
          include Requester

          attr_reader :stop_called

          def initialize(results)
            @results = results
            @index = 0
            @stop_called = false
          end

          def fetch(selector)
            @results[@index].tap { @index += 1 }
          end

          def stop
            @stop_called = true
          end
        end

        class MockSelectorStore
          include LaunchDarkly::Interfaces::DataSystem::SelectorStore

          def initialize(selector)
            @selector = selector
          end

          def selector
            @selector
          end
        end

        describe "#sync" do
          it "handles no changes" do
            change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes
            headers = {}
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            synchronizer = PollingDataSource.new(0.01, ListBasedRequester.new([polling_result]), logger)
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            valid = updates[0]

            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(valid.error).to be_nil
            expect(valid.revert_to_fdv1).to eq(false)
            expect(valid.environment_id).to be_nil
            expect(valid.change_set).not_to be_nil
            expect(valid.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE)
            expect(valid.change_set.changes.length).to eq(0)
          end

          it "handles empty changeset" do
            builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
            builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300))
            headers = {}
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            synchronizer = PollingDataSource.new(0.01, ListBasedRequester.new([polling_result]), logger)
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            valid = updates[0]

            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(valid.error).to be_nil
            expect(valid.revert_to_fdv1).to eq(false)
            expect(valid.environment_id).to be_nil
            expect(valid.change_set).not_to be_nil
            expect(valid.change_set.changes.length).to eq(0)
            expect(valid.change_set.selector).not_to be_nil
            expect(valid.change_set.selector.version).to eq(300)
            expect(valid.change_set.selector.state).to eq("p:SOMETHING:300")
            expect(valid.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
          end

          it "handles put objects" do
            builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
            builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            builder.add_put(
              LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              "flag-key",
              100,
              { key: "flag-key" }
            )
            change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300))
            headers = {}
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            synchronizer = PollingDataSource.new(0.01, ListBasedRequester.new([polling_result]), logger)
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            valid = updates[0]

            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(valid.error).to be_nil
            expect(valid.revert_to_fdv1).to eq(false)
            expect(valid.environment_id).to be_nil
            expect(valid.change_set).not_to be_nil
            expect(valid.change_set.changes.length).to eq(1)
            expect(valid.change_set.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT)
            expect(valid.change_set.changes[0].kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG)
            expect(valid.change_set.changes[0].key).to eq("flag-key")
            expect(valid.change_set.changes[0].object).to eq({ key: "flag-key" })
            expect(valid.change_set.changes[0].version).to eq(100)
            expect(valid.change_set.selector).not_to be_nil
            expect(valid.change_set.selector.version).to eq(300)
            expect(valid.change_set.selector.state).to eq("p:SOMETHING:300")
            expect(valid.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
          end

          it "handles delete objects" do
            builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
            builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            builder.add_delete(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG, "flag-key", 101)
            change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300))
            headers = {}
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            synchronizer = PollingDataSource.new(0.01, ListBasedRequester.new([polling_result]), logger)
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            valid = updates[0]

            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(valid.error).to be_nil
            expect(valid.revert_to_fdv1).to eq(false)
            expect(valid.environment_id).to be_nil
            expect(valid.change_set).not_to be_nil
            expect(valid.change_set.changes.length).to eq(1)
            expect(valid.change_set.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE)
            expect(valid.change_set.changes[0].kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG)
            expect(valid.change_set.changes[0].key).to eq("flag-key")
            expect(valid.change_set.changes[0].version).to eq(101)
            expect(valid.change_set.selector).not_to be_nil
            expect(valid.change_set.selector.version).to eq(300)
            expect(valid.change_set.selector.state).to eq("p:SOMETHING:300")
            expect(valid.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
          end

          it "generic error interrupts and recovers" do
            builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
            builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            builder.add_delete(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG, "flag-key", 101)
            change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300))
            headers = {}
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([
                                       LaunchDarkly::Result.fail("error for test"),
                polling_result,
                                     ]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break if updates.length >= 2
              end
            end

            thread.join(2)
            synchronizer.stop

            expect(updates.length).to eq(2)
            interrupted = updates[0]
            valid = updates[1]

            expect(interrupted.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(interrupted.error).not_to be_nil
            expect(interrupted.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::NETWORK_ERROR)
            expect(interrupted.error.status_code).to eq(0)
            expect(interrupted.error.message).to eq("error for test")
            expect(interrupted.revert_to_fdv1).to eq(false)
            expect(interrupted.environment_id).to be_nil

            expect(valid.change_set).not_to be_nil
            expect(valid.change_set.changes.length).to eq(1)
            expect(valid.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            expect(valid.change_set.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE)
          end

          it "recoverable error continues" do
            builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
            builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            builder.add_delete(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG, "flag-key", 101)
            change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300))
            headers = {}
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            failure = LaunchDarkly::Result.fail(
              "error for test",
              LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(408)
            )

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([failure, polling_result]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break if updates.length >= 2
              end
            end

            thread.join(2)
            synchronizer.stop

            expect(updates.length).to eq(2)
            interrupted = updates[0]
            valid = updates[1]

            expect(interrupted.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(interrupted.error).not_to be_nil
            expect(interrupted.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE)
            expect(interrupted.error.status_code).to eq(408)
            expect(interrupted.revert_to_fdv1).to eq(false)
            expect(interrupted.environment_id).to be_nil

            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(valid.error).to be_nil
            expect(valid.revert_to_fdv1).to eq(false)
            expect(valid.environment_id).to be_nil

            expect(valid.change_set).not_to be_nil
            expect(valid.change_set.changes.length).to eq(1)
            expect(valid.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            expect(valid.change_set.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE)
          end

          it "unrecoverable error shuts down" do
            failure = LaunchDarkly::Result.fail(
              "error for test",
              LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(401)
            )

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([failure]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            off = updates[0]
            expect(off.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::OFF)
            expect(off.error).not_to be_nil
            expect(off.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE)
            expect(off.error.status_code).to eq(401)
            expect(off.revert_to_fdv1).to eq(false)
            expect(off.environment_id).to be_nil
            expect(off.change_set).to be_nil
          end

          it "captures envid from success headers" do
            change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes
            headers = { LD_ENVID_HEADER => 'test-env-polling-123' }
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            synchronizer = PollingDataSource.new(0.01, ListBasedRequester.new([polling_result]), logger)
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            valid = updates[0]

            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(valid.error).to be_nil
            expect(valid.revert_to_fdv1).to eq(false)
            expect(valid.environment_id).to eq('test-env-polling-123')
          end

          it "captures envid and fallback from success with changeset" do
            builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
            builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            builder.add_put(
              LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              "flag-key",
              100,
              { key: "flag-key" }
            )
            change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300))
            headers = {
              LD_ENVID_HEADER => 'test-env-456',
              LD_FD_FALLBACK_HEADER => 'true',
            }
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            synchronizer = PollingDataSource.new(0.01, ListBasedRequester.new([polling_result]), logger)
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            valid = updates[0]

            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(valid.environment_id).to eq('test-env-456')
            expect(valid.revert_to_fdv1).to eq(true)
            expect(valid.change_set).not_to be_nil
            expect(valid.change_set.changes.length).to eq(1)
          end

          it "captures envid from error headers recoverable" do
            builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
            builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            builder.add_delete(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG, "flag-key", 101)
            change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300))
            headers_success = { LD_ENVID_HEADER => 'test-env-success' }
            polling_result = LaunchDarkly::Result.success([change_set, headers_success])

            headers_error = { LD_ENVID_HEADER => 'test-env-408' }
            failure = LaunchDarkly::Result.fail(
              "error for test",
              LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(408),
              headers_error
            )

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([failure, polling_result]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break if updates.length >= 2
              end
            end

            thread.join(2)
            synchronizer.stop

            expect(updates.length).to eq(2)
            interrupted = updates[0]
            valid = updates[1]

            expect(interrupted.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(interrupted.environment_id).to eq('test-env-408')
            expect(interrupted.error).not_to be_nil
            expect(interrupted.error.status_code).to eq(408)

            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(valid.environment_id).to eq('test-env-success')
          end

          it "captures envid from error headers unrecoverable" do
            headers_error = { LD_ENVID_HEADER => 'test-env-401' }
            failure = LaunchDarkly::Result.fail(
              "error for test",
              LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(401),
              headers_error
            )

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([failure]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            off = updates[0]

            expect(off.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::OFF)
            expect(off.environment_id).to eq('test-env-401')
            expect(off.error).not_to be_nil
            expect(off.error.status_code).to eq(401)
          end

          it "captures envid and fallback from error with fallback" do
            headers_error = {
              LD_ENVID_HEADER => 'test-env-503',
              LD_FD_FALLBACK_HEADER => 'true',
            }
            failure = LaunchDarkly::Result.fail(
              "error for test",
              LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(503),
              headers_error
            )

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([failure]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            interrupted = updates[0]

            # 503 is recoverable, so status is INTERRUPTED with fallback flag
            expect(interrupted.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(interrupted.revert_to_fdv1).to eq(true)
            expect(interrupted.environment_id).to eq('test-env-503')
          end

          it "captures envid from generic error with headers" do
            builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
            builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300))
            headers_success = {}
            polling_result = LaunchDarkly::Result.success([change_set, headers_success])

            headers_error = { LD_ENVID_HEADER => 'test-env-generic' }
            failure = LaunchDarkly::Result.fail("generic error for test", nil, headers_error)

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([failure, polling_result]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break if updates.length >= 2
              end
            end

            thread.join(2)
            synchronizer.stop

            expect(updates.length).to eq(2)
            interrupted = updates[0]
            valid = updates[1]

            expect(interrupted.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(interrupted.environment_id).to eq('test-env-generic')
            expect(interrupted.error).not_to be_nil
            expect(interrupted.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::NETWORK_ERROR)

            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
          end

          it "preserves fallback header on JSON parse error" do
            headers_with_fallback = {
              LD_ENVID_HEADER => 'test-env-parse-error',
              LD_FD_FALLBACK_HEADER => 'true',
            }
            # Simulate a JSON parse error with fallback header
            parse_error_result = LaunchDarkly::Result.fail(
              "Failed to parse JSON: unexpected token",
              JSON::ParserError.new("unexpected token"),
              headers_with_fallback
            )

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([parse_error_result]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break  # Break after first update to avoid polling again
              end
            end

            thread.join(1)
            synchronizer.stop

            expect(updates.length).to eq(1)
            interrupted = updates[0]

            # Verify the update signals INTERRUPTED state with fallback flag
            # Caller (FDv2) will handle shutdown based on revert_to_fdv1 flag
            expect(interrupted.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(interrupted.revert_to_fdv1).to eq(true)
            expect(interrupted.environment_id).to eq('test-env-parse-error')
            expect(interrupted.error).not_to be_nil
            expect(interrupted.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::NETWORK_ERROR)
          end

          it "signals fallback on recoverable HTTP error with fallback header" do
            headers_with_fallback = {
              LD_ENVID_HEADER => 'test-env-408',
              LD_FD_FALLBACK_HEADER => 'true',
            }
            # 408 is a recoverable error
            error_result = LaunchDarkly::Result.fail(
              "error for test",
              LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(408),
              headers_with_fallback
            )

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([error_result]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break # Break after first update to avoid polling again
              end
            end

            sleep 0.1 # Give thread time to process first update
            synchronizer.stop
            thread.join(1)

            expect(updates.length).to eq(1)
            interrupted = updates[0]

            # Should be INTERRUPTED (recoverable) with fallback flag set
            # Caller will handle shutdown based on revert_to_fdv1 flag
            expect(interrupted.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(interrupted.revert_to_fdv1).to eq(true)
            expect(interrupted.environment_id).to eq('test-env-408')
            expect(interrupted.error).not_to be_nil
            expect(interrupted.error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::ERROR_RESPONSE)
            expect(interrupted.error.status_code).to eq(408)
          end

          it "uses data but signals fallback on successful response with fallback header" do
            builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
            builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.new(state: "p:SOMETHING:300", version: 300))

            headers_with_fallback = {
              LD_ENVID_HEADER => 'test-env-success-fallback',
              LD_FD_FALLBACK_HEADER => 'true',
            }

            # Server sends successful response with valid data but also signals fallback
            success_result = LaunchDarkly::Result.success([change_set, headers_with_fallback])

            synchronizer = PollingDataSource.new(
              0.01,
              ListBasedRequester.new([success_result]),
              logger
            )
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
              end
            end

            sleep 0.1 # Give thread time to process first update
            synchronizer.stop
            thread.join(1)

            expect(updates.length).to eq(1)
            valid = updates[0]

            # Should use the data (VALID state) but signal future fallback
            expect(valid.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(valid.revert_to_fdv1).to eq(true)
            expect(valid.environment_id).to eq('test-env-success-fallback')
            expect(valid.error).to be_nil
            expect(valid.change_set).not_to be_nil  # Data is provided
          end

          it "closes requester when sync exits" do
            change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes
            headers = {}
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            requester = RequesterWithCleanup.new([polling_result])
            synchronizer = PollingDataSource.new(0.01, requester, logger)
            updates = []

            thread = Thread.new do
              synchronizer.sync(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)) do |update|
                updates << update
                break
              end
            end

            thread.join(1)
            expect(requester.stop_called).to eq(true)
          end

          it "closes requester when fetch is called" do
            change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes
            headers = {}
            polling_result = LaunchDarkly::Result.success([change_set, headers])

            requester = RequesterWithCleanup.new([polling_result])
            synchronizer = PollingDataSource.new(0.01, requester, logger)

            # Call fetch (used when PollingDataSource is an Initializer)
            basis_result = synchronizer.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(basis_result).to be_success
            expect(requester.stop_called).to eq(true)
          end
        end
      end
    end
  end
end
