# frozen_string_literal: true

require "spec_helper"
require "ldclient-rb/impl/data_system/fdv2"
require "ldclient-rb/integrations/test_data_v2"
require "ldclient-rb/data_system"
require "ldclient-rb/impl/data_system"
require "ldclient-rb/impl/data_store"

module LaunchDarkly
  module Impl
    module DataSystem
      describe "FDv2 Persistent Store Recovery" do
        let(:sdk_key) { "test-sdk-key" }
        let(:test_logger) do
          logger = ::Logger.new($stdout)
          logger.level = ::Logger::DEBUG
          logger
        end
        let(:config) do
          logger = ::Logger.new(STDOUT)
          logger.level = ::Logger::DEBUG
          LaunchDarkly::Config.new(logger: logger)
        end

        # Stub feature store for testing
        class StubFeatureStore
          include LaunchDarkly::Interfaces::FeatureStore

          attr_reader :init_called_count, :upsert_calls, :data

          def initialize(initial_data = nil)
            @data = {
              LaunchDarkly::Impl::DataStore::FEATURES => {},
              LaunchDarkly::Impl::DataStore::SEGMENTS => {},
            }
            @initialized = false
            @available = true
            @monitoring_enabled = true  # Enable monitoring by default
            @init_called_count = 0
            @upsert_calls = []

            init(initial_data) if initial_data
          end

          def init(all_data)
            @init_called_count += 1
            if all_data
              @data[LaunchDarkly::Impl::DataStore::FEATURES] = (all_data[LaunchDarkly::Impl::DataStore::FEATURES] || {}).dup
              @data[LaunchDarkly::Impl::DataStore::SEGMENTS] = (all_data[LaunchDarkly::Impl::DataStore::SEGMENTS] || {}).dup
            end
            @initialized = true
          end

          def get(kind, key)
            item = @data[kind][key.to_sym] || @data[kind][key.to_s]
            item && !item[:deleted] ? item : nil
          end

          def all(kind)
            @data[kind].reject { |_k, v| v[:deleted] }
          end

          def delete(kind, key, version)
            existing = @data[kind][key]
            if !existing || existing[:version] < version
              @data[kind][key] = { key: key, version: version, deleted: true }
            end
          end

          def upsert(kind, item)
            @upsert_calls << [kind, item[:key], item[:version]]
            key = item[:key]
            existing = @data[kind][key]
            if !existing || existing[:version] < item[:version]
              @data[kind][key] = item
            end
          end

          def initialized?
            @initialized
          end

          def available?
            @available
          end

          def monitoring_enabled?
            @monitoring_enabled
          end

          def stop
            # No-op
          end

          # Test helpers
          def set_available(available)
            @available = available
          end

          def enable_monitoring
            @monitoring_enabled = true
          end

          def reset_operation_tracking
            @init_called_count = 0
            @upsert_calls = []
          end

          def get_data_snapshot
            {
              LaunchDarkly::Impl::DataStore::FEATURES => @data[LaunchDarkly::Impl::DataStore::FEATURES].dup,
              LaunchDarkly::Impl::DataStore::SEGMENTS => @data[LaunchDarkly::Impl::DataStore::SEGMENTS].dup,
            }
          end
        end

        it "flushes in-memory store to persistent store when it recovers from outage with stale data" do
          persistent_store = StubFeatureStore.new

          # Create and populate synchronizer BEFORE building config
          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers(nil)
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(persistent_store, :read_write)
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)
          ready_event = fdv2.start

          expect(ready_event.wait(3)).to be true

          # Verify data from synchronizer is in the persistent store
          snapshot = persistent_store.get_data_snapshot
          expect(snapshot[LaunchDarkly::Impl::DataStore::FEATURES]).to have_key(:flagkey)
          expect(snapshot[LaunchDarkly::Impl::DataStore::FEATURES][:flagkey][:on]).to be true

          # Reset tracking to isolate recovery behavior
          persistent_store.reset_operation_tracking

          # Simulate a new flag being added while store is "offline"
          flag_changed = Concurrent::Event.new
          changes = []
          listener = Object.new
          listener.define_singleton_method(:update) do |flag_change|
            changes << flag_change
            flag_changed.set if flag_change.key == :newflag
          end
          fdv2.flag_change_broadcaster.add_listener(listener)

          td_synchronizer.update(td_synchronizer.flag("newflag").on(false))

          # Wait for the flag to propagate
          expect(flag_changed.wait(2)).to be true

          # Now simulate the persistent store coming back online with stale data
          # by triggering the recovery callback directly
          stale_status = LaunchDarkly::Interfaces::DataStore::Status.new(true, true)
          fdv2.send(:persistent_store_outage_recovery, stale_status)

          # Verify that init was called on the persistent store (flushing in-memory data)
          expect(persistent_store.init_called_count).to be > 0

          # Verify both flags are now in the persistent store
          snapshot = persistent_store.get_data_snapshot
          expect(snapshot[LaunchDarkly::Impl::DataStore::FEATURES]).to have_key(:flagkey)
          expect(snapshot[LaunchDarkly::Impl::DataStore::FEATURES]).to have_key(:newflag)

          fdv2.stop
        end

        it "does not flush when store comes back online without stale data" do
          persistent_store = StubFeatureStore.new

          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers(nil)
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(persistent_store, :read_write)
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)
          ready_event = fdv2.start

          expect(ready_event.wait(2)).to be true

          # Reset tracking
          persistent_store.reset_operation_tracking

          # Simulate store coming back online but NOT stale (data is fresh)
          fresh_status = LaunchDarkly::Interfaces::DataStore::Status.new(true, false)
          fdv2.send(:persistent_store_outage_recovery, fresh_status)

          # Verify that init was NOT called (no flush needed)
          expect(persistent_store.init_called_count).to eq(0)

          fdv2.stop
        end

        it "does not flush when store is unavailable" do
          persistent_store = StubFeatureStore.new

          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers(nil)
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(persistent_store, :read_write)
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)
          ready_event = fdv2.start

          expect(ready_event.wait(2)).to be true

          # Reset tracking
          persistent_store.reset_operation_tracking

          # Simulate store being unavailable (even if marked as stale)
          unavailable_status = LaunchDarkly::Interfaces::DataStore::Status.new(false, true)
          fdv2.send(:persistent_store_outage_recovery, unavailable_status)

          # Verify that init was NOT called (store is not available)
          expect(persistent_store.init_called_count).to eq(0)

          fdv2.stop
        end

        it "works in READ_WRITE mode with persistent store" do
          persistent_store = StubFeatureStore.new

          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers(nil)
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(persistent_store, :read_write)
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)
          ready_event = fdv2.start

          expect(ready_event.wait(2)).to be true

          # Verify data was written to persistent store
          expect(persistent_store.init_called_count).to be >= 1

          # Verify the flag is in the persistent store
          snapshot = persistent_store.get_data_snapshot
          expect(snapshot[LaunchDarkly::Impl::DataStore::FEATURES]).to have_key(:flagkey)

          fdv2.stop
        end

        it "works in READ_ONLY mode with persistent store" do
          # Pre-populate persistent store
          initial_data = {
            LaunchDarkly::Impl::DataStore::FEATURES => {
              :existingflag => {
                key: "existingflag",
                version: 1,
                on: true,
                variations: [true, false],
                fallthrough: { variation: 0 },
              },
            },
            LaunchDarkly::Impl::DataStore::SEGMENTS => {},
          }

          persistent_store = StubFeatureStore.new(initial_data)
          persistent_store.reset_operation_tracking

          # Create synchronizer with new data
          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("newflag").on(true))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers(nil)
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(persistent_store, :read_only)
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)
          ready_event = fdv2.start

          expect(ready_event.wait(2)).to be true

          # In READ_ONLY mode, no writes should happen to persistent store
          expect(persistent_store.init_called_count).to eq(0)
          expect(persistent_store.upsert_calls).to be_empty

          fdv2.stop
        end

        it "writes delta updates to persistent store in READ_WRITE mode" do
          persistent_store = StubFeatureStore.new

          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers(nil)
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(persistent_store, :read_write)
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)

          ready_event = fdv2.start
          expect(ready_event.wait(2)).to be true

          # Wait a bit for initial sync to complete
          sleep 0.2

          # Reset tracking after initial sync
          persistent_store.reset_operation_tracking

          # Set up flag change listener to detect the update
          flag_changed = Concurrent::Event.new
          listener = Object.new
          listener.define_singleton_method(:update) do |flag_change|
            flag_changed.set if flag_change.key == :flagkey
          end

          fdv2.flag_change_broadcaster.add_listener(listener)

          # Make a delta update
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(false))

          # Wait for flag change to propagate
          expect(flag_changed.wait(3)).to be true

          # Verify the update was written to persistent store via upsert
          # (The test verifies upsert was called; exact timing of snapshot may vary)
          expect(persistent_store.upsert_calls).not_to be_empty
          expect(persistent_store.upsert_calls.any? { |call| call[1] == "flagkey" && call[2] >= 2 }).to be true  # version should be >= 2 for the update

          fdv2.stop
        end

        it "does not write delta updates to persistent store in READ_ONLY mode" do
          persistent_store = StubFeatureStore.new

          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers(nil)
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(persistent_store, :read_only)
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)

          # Set up flag change listener
          flag_changed = Concurrent::Event.new
          change_count = 0

          listener = Object.new
          listener.define_singleton_method(:update) do |_flag_change|
            change_count += 1
            flag_changed.set if change_count == 2
          end

          fdv2.flag_change_broadcaster.add_listener(listener)
          ready_event = fdv2.start

          expect(ready_event.wait(2)).to be true

          persistent_store.reset_operation_tracking

          # Make a delta update
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(false))

          # Wait for flag change
          expect(flag_changed.wait(2)).to be true

          # Verify NO updates were written to persistent store in READ_ONLY mode
          expect(persistent_store.upsert_calls).to be_empty

          fdv2.stop
        end

        it "persists data from both initializer and synchronizer in READ_WRITE mode" do
          persistent_store = StubFeatureStore.new

          # Create initializer with one flag
          td_initializer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_initializer.update(td_initializer.flag("init-flag").on(true))

          # Create synchronizer with another flag
          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("sync-flag").on(false))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers([td_initializer.method(:build_initializer)])
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(persistent_store, :read_write)
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)

          # Set up flag change listener to detect when synchronizer data arrives
          sync_flag_arrived = Concurrent::Event.new

          listener = Object.new
          listener.define_singleton_method(:update) do |flag_change|
            sync_flag_arrived.set if flag_change.key == :"sync-flag"
          end

          fdv2.flag_change_broadcaster.add_listener(listener)
          ready_event = fdv2.start

          expect(ready_event.wait(2)).to be true

          # Wait for synchronizer to fully initialize
          expect(sync_flag_arrived.wait(2)).to be true

          # The synchronizer flag should be in the persistent store
          # (synchronizer does a full data set transfer, replacing initializer data)
          snapshot = persistent_store.get_data_snapshot
          expect(snapshot[LaunchDarkly::Impl::DataStore::FEATURES]).not_to have_key(:"init-flag")
          expect(snapshot[LaunchDarkly::Impl::DataStore::FEATURES]).to have_key(:"sync-flag")

          fdv2.stop
        end

        it "handles data store status provider correctly" do
          persistent_store = StubFeatureStore.new

          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers(nil)
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(persistent_store, :read_write)
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)

          # Verify data store status provider exists
          status_provider = fdv2.data_store_status_provider
          expect(status_provider).not_to be_nil

          # Get initial status
          status = status_provider.status
          expect(status).not_to be_nil
          expect(status.available).to be true

          ready_event = fdv2.start
          expect(ready_event.wait(2)).to be true

          fdv2.stop
        end

        it "has data store status provider even without persistent store" do
          td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
          td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))

          data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
            .initializers(nil)
            .synchronizers(td_synchronizer.method(:build_synchronizer))
            .data_store(nil, :read_write)  # No persistent store
            .build

          fdv2 = FDv2.new(sdk_key, config, data_system_config)

          # Status provider should exist but not be monitoring
          status_provider = fdv2.data_store_status_provider
          expect(status_provider).not_to be_nil

          ready_event = fdv2.start
          expect(ready_event.wait(2)).to be true

          fdv2.stop
        end
      end
    end
  end
end
