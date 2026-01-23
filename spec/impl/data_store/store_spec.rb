# frozen_string_literal: true

require "spec_helper"
require "ldclient-rb/impl/data_store/store"
require "ldclient-rb/impl/broadcaster"
require "ldclient-rb/impl/data_store"
require "ldclient-rb/interfaces/data_system"

module LaunchDarkly
  module Impl
    module DataStore
      describe Store do
        let(:logger) { double.as_null_object }
        let(:flag_change_broadcaster) { LaunchDarkly::Impl::Broadcaster.new(Concurrent::SingleThreadExecutor.new, logger) }
        let(:change_set_broadcaster) { LaunchDarkly::Impl::Broadcaster.new(Concurrent::SingleThreadExecutor.new, logger) }
        subject { Store.new(flag_change_broadcaster, change_set_broadcaster, logger) }

        let(:flag_key) { :test_flag }  # Use symbol like TestDataV2 does
        let(:flag_data) do
          {
            key: flag_key.to_s,  # key field in the object should be string
            version: 1,
            on: true,
            variations: [true, false],
            fallthrough: { variation: 0 },
          }
        end

        let(:segment_key) { :test_segment }  # Use symbol like TestDataV2 does
        let(:segment_data) do
          {
            key: segment_key.to_s,  # key field in the object should be string
            version: 1,
            included: ["user1"],
            excluded: [],
            rules: [],
          }
        end

        # Stub feature store for testing persistence
        class StubPersistentStore
          include LaunchDarkly::Interfaces::FeatureStore

          attr_reader :init_called_count, :upsert_calls, :data, :init_errors

          def initialize(should_fail: false)
            @data = {
              LaunchDarkly::Impl::DataStore::FEATURES => {},
              LaunchDarkly::Impl::DataStore::SEGMENTS => {},
            }
            @initialized = false
            @init_called_count = 0
            @upsert_calls = []
            @should_fail = should_fail
            @init_errors = []
          end

          def init(all_data)
            @init_called_count += 1
            if @should_fail
              error = RuntimeError.new("Simulated persistent store failure")
              @init_errors << error
              raise error
            end
            @data[LaunchDarkly::Impl::DataStore::FEATURES] = (all_data[LaunchDarkly::Impl::DataStore::FEATURES] || {}).dup
            @data[LaunchDarkly::Impl::DataStore::SEGMENTS] = (all_data[LaunchDarkly::Impl::DataStore::SEGMENTS] || {}).dup
            @initialized = true
          end

          def get(kind, key)
            # Store uses symbol keys internally
            item = @data[kind][key.to_sym] || @data[kind][key.to_s]
            item && !item[:deleted] ? item : nil
          end

          def all(kind)
            @data[kind].reject { |_k, v| v[:deleted] }
          end

          def upsert(kind, item)
            @upsert_calls << [kind, item[:key], item[:version]]
            # Use symbol keys consistently
            key = item[:key].is_a?(Symbol) ? item[:key] : item[:key].to_sym
            @data[kind][key] = item
          end

          def delete(kind, key, version)
            @data[kind][key.to_sym] = { key: key, version: version, deleted: true }
          end

          def initialized?
            @initialized
          end

          def stop
            # No-op
          end

          def reset_tracking
            @init_called_count = 0
            @upsert_calls = []
            @init_errors = []
          end
        end

        describe "#apply" do
          it "applies TRANSFER_FULL changeset with set_basis" do
            change = LaunchDarkly::Interfaces::DataSystem::Change.new(
              action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: flag_key,
              version: 1,
              object: flag_data
            )

            change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
              intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
              changes: [change],
              selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
            )

            subject.apply(change_set, false)

            expect(subject.initialized?).to be true
            # InMemoryFeatureStoreV2's get method handles both string and symbol keys
            result = subject.get_active_store.get(FEATURES, flag_key)
            expect(result).not_to be_nil
            expect(result.key).to eq(flag_key.to_s)  # key field is string
          end

          it "applies TRANSFER_CHANGES changeset with apply_delta" do
            # First initialize with some data
            initial_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
              action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: flag_key,
              version: 1,
              object: flag_data
            )

            initial_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
              intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
              changes: [initial_change],
              selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
            )

            subject.apply(initial_change_set, false)

            # Now apply a delta
            updated_flag_data = flag_data.merge(version: 2, on: false)
            delta_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
              action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: flag_key,
              version: 2,
              object: updated_flag_data
            )

            delta_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
              intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_CHANGES,
              changes: [delta_change],
              selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
            )

            subject.apply(delta_change_set, false)

            result = subject.get_active_store.get(FEATURES, flag_key)
            expect(result.version).to eq(2)
            expect(result.on).to be false
          end

          it "handles TRANSFER_NONE as no-op" do
            change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
              intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE,
              changes: [],
              selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
            )

            subject.apply(change_set, false)
            expect(subject.initialized?).to be false
          end

          it "applies DELETE changes" do
            # Initialize with flag
            put_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
              action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: flag_key,
              version: 1,
              object: flag_data
            )

            init_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
              intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
              changes: [put_change],
              selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
            )

            subject.apply(init_change_set, false)
            expect(subject.get_active_store.get(FEATURES, flag_key)).not_to be_nil

            # Delete the flag
            delete_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
              action: LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: flag_key,
              version: 2,
              object: nil
            )

            delete_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
              intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_CHANGES,
              changes: [delete_change],
              selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
            )

            subject.apply(delete_change_set, false)
            expect(subject.get_active_store.get(FEATURES, flag_key)).to be_nil
          end

          it "broadcasts changeset to listeners" do
            received_changesets = []
            listener = Object.new
            listener.define_singleton_method(:update) do |change_set|
              received_changesets << change_set
            end
            change_set_broadcaster.add_listener(listener)

            change = LaunchDarkly::Interfaces::DataSystem::Change.new(
              action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
              kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key: flag_key,
              version: 1,
              object: flag_data
            )

            change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
              intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
              changes: [change],
              selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
            )

            subject.apply(change_set, false)

            # Give broadcaster time to notify
            sleep 0.1

            expect(received_changesets).not_to be_empty
            expect(received_changesets.first.changes.first.key).to eq(flag_key)
          end
        end

        describe "#commit" do
          context "without persistent store" do
            it "returns nil and does nothing" do
              change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_data
              )

              change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(change_set, false)

              error = subject.commit
              expect(error).to be_nil
            end
          end

          context "with writable persistent store" do
            let(:persistent_store) { StubPersistentStore.new }

            before do
              subject.with_persistence(persistent_store, true, nil)
            end

            it "writes in-memory data to persistent store" do
              # Add data to in-memory store
              change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_data
              )

              change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(change_set, true)  # persist=true
              persistent_store.reset_tracking

              # Commit should write to persistent store
              error = subject.commit
              expect(error).to be_nil
              expect(persistent_store.init_called_count).to eq(1)

              # Verify data in persistent store
              stored_flag = persistent_store.get(FEATURES, flag_key)
              expect(stored_flag).not_to be_nil
              expect(stored_flag[:key]).to eq(flag_key.to_s)  # key field is string
            end

            it "encodes data correctly before writing" do
              flag_with_complex_data = flag_data.merge(
                rules: [{ id: "rule1", variation: 0 }],
                prerequisites: [{ key: "prereq1", variation: 1 }]
              )

              change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_with_complex_data
              )

              change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(change_set, true)
              persistent_store.reset_tracking

              error = subject.commit
              expect(error).to be_nil

              stored_flag = persistent_store.get(FEATURES, flag_key)
              expect(stored_flag[:key]).to eq(flag_key.to_s)  # key field is string
              expect(stored_flag[:version]).to eq(1)
            end

            it "returns exception when persistent store fails" do
              failing_store = StubPersistentStore.new(should_fail: true)
              subject.with_persistence(failing_store, true, nil)

              change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_data
              )

              change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(change_set, true)

              error = subject.commit
              expect(error).to be_a(RuntimeError)
              expect(error.message).to include("Simulated persistent store failure")
            end
          end

          context "with read-only persistent store" do
            let(:persistent_store) { StubPersistentStore.new }

            before do
              subject.with_persistence(persistent_store, false, nil)  # writable=false
            end

            it "does not write to read-only store" do
              change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_data
              )

              change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(change_set, true)  # persist=true
              persistent_store.reset_tracking

              error = subject.commit
              expect(error).to be_nil
              expect(persistent_store.init_called_count).to eq(0)
            end
          end
        end

        describe "persistent store integration" do
          let(:persistent_store) { StubPersistentStore.new }

          context "in READ_WRITE mode" do
            before do
              subject.with_persistence(persistent_store, true, nil)
            end

            it "writes full data sets to persistent store" do
              change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_data
              )

              change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(change_set, true)

              expect(persistent_store.init_called_count).to be >= 1
              stored_flag = persistent_store.get(FEATURES, flag_key)
              expect(stored_flag).not_to be_nil
            end

            it "writes delta updates to persistent store using upsert" do
              # Initialize
              init_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_data
              )

              init_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [init_change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(init_change_set, true)
              persistent_store.reset_tracking

              # Apply delta
              updated_flag_data = flag_data.merge(version: 2, on: false)
              delta_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 2,
                object: updated_flag_data
              )

              delta_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_CHANGES,
                changes: [delta_change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(delta_change_set, true)

              expect(persistent_store.upsert_calls).not_to be_empty
              expect(persistent_store.upsert_calls.any? { |call| call[1] == flag_key.to_s }).to be true  # upsert stores string key
            end

            it "writes DELETE operations to persistent store" do
              # Initialize
              init_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_data
              )

              init_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [init_change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(init_change_set, true)
              persistent_store.reset_tracking

              # Delete
              delete_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 2,
                object: nil
              )

              delete_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_CHANGES,
                changes: [delete_change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(delete_change_set, true)

              expect(persistent_store.upsert_calls).not_to be_empty
              # Verify deleted flag was written
              stored_flag = persistent_store.get(FEATURES, flag_key)
              expect(stored_flag).to be_nil  # get returns nil for deleted items
            end
          end

          context "in READ_ONLY mode" do
            before do
              subject.with_persistence(persistent_store, false, nil)
            end

            it "does not write to persistent store on full data set" do
              change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_data
              )

              change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(change_set, true)

              expect(persistent_store.init_called_count).to eq(0)
            end

            it "does not write to persistent store on delta updates" do
              # Initialize (this won't write due to READ_ONLY)
              init_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: flag_key,
                version: 1,
                object: flag_data
              )

              init_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL,
                changes: [init_change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(init_change_set, true)

              # Apply delta
              delta_change = LaunchDarkly::Interfaces::DataSystem::Change.new(
                action: LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT,
                kind: LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                key: "new-flag",
                version: 1,
                object: flag_data.merge(key: "new-flag")
              )

              delta_change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSet.new(
                intent_code: LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_CHANGES,
                changes: [delta_change],
                selector: LaunchDarkly::Interfaces::DataSystem::Selector.no_selector
              )

              subject.apply(delta_change_set, true)

              expect(persistent_store.upsert_calls).to be_empty
            end
          end
        end
      end
    end
  end
end
