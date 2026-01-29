require "spec_helper"
require "ldclient-rb/impl/data_system/fdv2"
require "ldclient-rb/integrations/test_data_v2"
require "ldclient-rb/data_system"
require "ldclient-rb/impl/data_system"

module LaunchDarkly
  module Impl
    module DataSystem
      # Helper class that wraps a data source in a builder interface for testing
      class MockBuilder
        def initialize(data_source)
          @data_source = data_source
        end

        def build(_sdk_key, _config)
          @data_source
        end
      end

      describe FDv2 do
        let(:sdk_key) { "test-sdk-key" }
        let(:config) { LaunchDarkly::Config.new(logger: $null_log) }

        describe "two-phase initialization" do
          it "initializes from initializer then syncs from synchronizer" do
            td_initializer = LaunchDarkly::Integrations::TestDataV2.data_source
            td_initializer.update(td_initializer.flag("flagkey").on(true))

            td_synchronizer = LaunchDarkly::Integrations::TestDataV2.data_source
            # Set this to true, and then to false to ensure the version number exceeded
            # the initializer version number. Otherwise, they start as the same version
            # and the latest value is ignored.
            td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))
            td_synchronizer.update(td_synchronizer.flag("flagkey").on(false))

            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers([td_initializer.test_data_ds_builder])
              .synchronizers([td_synchronizer.test_data_ds_builder])
              .build

            fdv2 = FDv2.new(sdk_key, config, data_system_config)

            initialized = Concurrent::Event.new
            modified = Concurrent::Event.new
            changes = []
            count = 0

            listener = Object.new
            listener.define_singleton_method(:update) do |flag_change|
              count += 1
              changes << flag_change

              initialized.set if count == 2
              modified.set if count == 3
            end

            fdv2.flag_change_broadcaster.add_listener(listener)

            ready_event = fdv2.start
            expect(ready_event.wait(2)).to be true
            expect(initialized.wait(1)).to be true

            td_synchronizer.update(td_synchronizer.flag("flagkey").on(true))
            expect(modified.wait(1)).to be true

            expect(changes.length).to eq(3)
            expect(changes[0].key).to eq(:flagkey)
            expect(changes[1].key).to eq(:flagkey)
            expect(changes[2].key).to eq(:flagkey)

            fdv2.stop
          end
        end

        describe "stopping FDv2" do
          it "prevents flag updates after stop" do
            td = LaunchDarkly::Integrations::TestDataV2.data_source
            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers(nil)
              .synchronizers([td.test_data_ds_builder])
              .build

            fdv2 = FDv2.new(sdk_key, config, data_system_config)

            changed = Concurrent::Event.new
            changes = []

            listener = Object.new
            listener.define_singleton_method(:update) do |flag_change|
              changes << flag_change
              changed.set
            end

            fdv2.flag_change_broadcaster.add_listener(listener)

            ready_event = fdv2.start
            expect(ready_event.wait(1)).to be true

            fdv2.stop

            td.update(td.flag("flagkey").on(false))
            expect(changed.wait(1)).to be_falsey, "Flag change listener was erroneously called"
            expect(changes.length).to eq(0)
          end
        end

        describe "data availability" do
          it "reports refreshed availability when data is loaded" do
            td = LaunchDarkly::Integrations::TestDataV2.data_source
            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers(nil)
              .synchronizers([td.test_data_ds_builder])
              .build

            fdv2 = FDv2.new(sdk_key, config, data_system_config)

            ready_event = fdv2.start
            expect(ready_event.wait(1)).to be true

            expect(DataAvailability.at_least?(fdv2.data_availability, DataAvailability::REFRESHED)).to be true
            expect(DataAvailability.at_least?(fdv2.target_availability, DataAvailability::REFRESHED)).to be true

            fdv2.stop
          end
        end

        describe "secondary synchronizer fallback" do
          it "falls back to secondary synchronizer when primary fails" do
            mock_primary = double("primary_synchronizer")
            allow(mock_primary).to receive(:name).and_return("mock-primary")
            allow(mock_primary).to receive(:stop)
            # Return empty - sync yields nothing (synchronizer fails)
            allow(mock_primary).to receive(:sync)

            td = LaunchDarkly::Integrations::TestDataV2.data_source
            td.update(td.flag("flagkey").on(true))

            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers([td.test_data_ds_builder])
              .synchronizers([
                               MockBuilder.new(mock_primary),
                td.test_data_ds_builder,
                             ])
              .build

            changed = Concurrent::Event.new
            changes = []
            count = 0

            listener = Object.new
            listener.define_singleton_method(:update) do |flag_change|
              count += 1
              changes << flag_change
              changed.set if count == 2
            end

            fdv2 = FDv2.new(sdk_key, config, data_system_config)
            fdv2.flag_change_broadcaster.add_listener(listener)

            ready_event = fdv2.start
            expect(ready_event.wait(2)).to be true

            td.update(td.flag("flagkey").on(false))
            expect(changed.wait(2)).to be true

            expect(changes.length).to eq(2)
            expect(changes[0].key).to eq(:flagkey)
            expect(changes[1].key).to eq(:flagkey)

            fdv2.stop
          end
        end

        describe "shutdown when both synchronizers fail" do
          it "shuts down data source when both primary and secondary fail" do
            mock_primary = double("primary_synchronizer")
            allow(mock_primary).to receive(:name).and_return("mock-primary")
            allow(mock_primary).to receive(:stop)
            # Return empty - sync yields nothing (synchronizer fails)
            allow(mock_primary).to receive(:sync)

            mock_secondary = double("secondary_synchronizer")
            allow(mock_secondary).to receive(:name).and_return("mock-secondary")
            allow(mock_secondary).to receive(:stop)
            # Return empty - sync yields nothing (synchronizer fails)
            allow(mock_secondary).to receive(:sync)

            td = LaunchDarkly::Integrations::TestDataV2.data_source
            td.update(td.flag("flagkey").on(true))

            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers([td.test_data_ds_builder])
              .synchronizers([
                               MockBuilder.new(mock_primary),
                MockBuilder.new(mock_secondary),
                             ])
              .build

            changed = Concurrent::Event.new

            listener = Object.new
            listener.define_singleton_method(:update) do |status|
              changed.set if status.state == LaunchDarkly::Interfaces::DataSource::Status::OFF
            end

            fdv2 = FDv2.new(sdk_key, config, data_system_config)
            fdv2.data_source_status_provider.add_listener(listener)

            ready_event = fdv2.start
            expect(ready_event.wait(2)).to be true

            expect(changed.wait(5)).to be true
            expect(fdv2.data_source_status_provider.status.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::OFF)

            fdv2.stop
          end
        end

        describe "FDv1 fallback on polling error with header" do
          it "falls back to FDv1 when synchronizer signals revert_to_fdv1" do
            mock_primary = double("primary_synchronizer")
            allow(mock_primary).to receive(:name).and_return("mock-primary")
            allow(mock_primary).to receive(:stop)

            # Simulate a synchronizer that yields an OFF state with revert_to_fdv1=true
            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
              revert_to_fdv1: true
            )
            allow(mock_primary).to receive(:sync).and_yield(update)

            # Create FDv1 fallback data source with actual data
            td_fdv1 = LaunchDarkly::Integrations::TestDataV2.data_source
            td_fdv1.update(td_fdv1.flag("fdv1flag").on(true))

            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers(nil)
              .synchronizers([MockBuilder.new(mock_primary)])
              .fdv1_compatible_synchronizer(td_fdv1.test_data_ds_builder)
              .build

            changed = Concurrent::Event.new
            changes = []

            listener = Object.new
            listener.define_singleton_method(:update) do |flag_change|
              changes << flag_change
              changed.set
            end

            fdv2 = FDv2.new(sdk_key, config, data_system_config)
            fdv2.flag_change_broadcaster.add_listener(listener)

            ready_event = fdv2.start
            expect(ready_event.wait(1)).to be true

            # Update flag in FDv1 data source to verify it's being used
            td_fdv1.update(td_fdv1.flag("fdv1flag").on(false))
            expect(changed.wait(10)).to be true

            # Verify we got flag changes from FDv1
            expect(changes.length).to be > 0
            expect(changes.any? { |change| change.key == :fdv1flag }).to be true

            fdv2.stop
          end
        end

        describe "FDv1 fallback on polling success with header" do
          it "falls back to FDv1 even when primary yields valid data with revert_to_fdv1" do
            mock_primary = double("primary_synchronizer")
            allow(mock_primary).to receive(:name).and_return("mock-primary")
            allow(mock_primary).to receive(:stop)

            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
              revert_to_fdv1: true
            )
            allow(mock_primary).to receive(:sync).and_yield(update)

            # Create FDv1 fallback data source
            td_fdv1 = LaunchDarkly::Integrations::TestDataV2.data_source
            td_fdv1.update(td_fdv1.flag("fdv1fallbackflag").on(true))

            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers(nil)
              .synchronizers([MockBuilder.new(mock_primary)])
              .fdv1_compatible_synchronizer(td_fdv1.test_data_ds_builder)
              .build

            changed = Concurrent::Event.new
            changes = []
            count = 0

            listener = Object.new
            listener.define_singleton_method(:update) do |flag_change|
              count += 1
              changes << flag_change
              changed.set
            end

            fdv2 = FDv2.new(sdk_key, config, data_system_config)
            fdv2.flag_change_broadcaster.add_listener(listener)

            ready_event = fdv2.start
            expect(ready_event.wait(2)).to be true

            # Wait for first flag change (from FDv1 synchronizer starting)
            expect(changed.wait(3)).to be true
            changed = Concurrent::Event.new  # Reset for second change

            # Trigger a flag update in FDv1
            td_fdv1.update(td_fdv1.flag("fdv1fallbackflag").on(false))
            expect(changed.wait(2)).to be true

            # Verify FDv1 is active and we got both changes
            expect(changes.length).to eq(2)
            expect(changes.all? { |change| change.key == :fdv1fallbackflag }).to be true

            fdv2.stop
          end
        end

        describe "FDv1 fallback with initializer" do
          it "falls back to FDv1 and replaces initialized data" do
            # Initialize with some data
            td_initializer = LaunchDarkly::Integrations::TestDataV2.data_source
            td_initializer.update(td_initializer.flag("initialflag").on(true))

            # Create mock primary that signals fallback
            mock_primary = double("primary_synchronizer")
            allow(mock_primary).to receive(:name).and_return("mock-primary")
            allow(mock_primary).to receive(:stop)

            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
              revert_to_fdv1: true
            )
            allow(mock_primary).to receive(:sync).and_yield(update)

            # Create FDv1 fallback with different data
            td_fdv1 = LaunchDarkly::Integrations::TestDataV2.data_source
            td_fdv1.update(td_fdv1.flag("fdv1replacementflag").on(true))

            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers([td_initializer.test_data_ds_builder])
              .synchronizers([MockBuilder.new(mock_primary)])
              .fdv1_compatible_synchronizer(td_fdv1.test_data_ds_builder)
              .build

            changed = Concurrent::Event.new
            changes = []

            listener = Object.new
            listener.define_singleton_method(:update) do |flag_change|
              changes << flag_change
              changed.set if changes.length >= 2
            end

            fdv2 = FDv2.new(sdk_key, config, data_system_config)
            fdv2.flag_change_broadcaster.add_listener(listener)

            ready_event = fdv2.start
            expect(ready_event.wait(2)).to be true
            expect(changed.wait(3)).to be true

            # Verify we got changes for both flags
            flag_keys = changes.map { |change| change.key }
            expect(flag_keys).to include(:initialflag)
            expect(flag_keys).to include(:fdv1replacementflag)

            fdv2.stop
          end
        end

        describe "no fallback without header" do
          it "does not fall back to FDv1 when revert_to_fdv1 is false" do
            mock_primary = double("primary_synchronizer")
            allow(mock_primary).to receive(:name).and_return("mock-primary")
            allow(mock_primary).to receive(:stop)

            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
              revert_to_fdv1: false
            )
            allow(mock_primary).to receive(:sync).and_yield(update)

            # Create mock secondary
            mock_secondary = double("secondary_synchronizer")
            allow(mock_secondary).to receive(:name).and_return("mock-secondary")
            allow(mock_secondary).to receive(:stop)

            valid_update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
              revert_to_fdv1: false
            )
            allow(mock_secondary).to receive(:sync).and_yield(valid_update)

            # Create FDv1 fallback (should not be used)
            td_fdv1 = LaunchDarkly::Integrations::TestDataV2.data_source
            td_fdv1.update(td_fdv1.flag("fdv1-should-not-appear").on(true))

            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers(nil)
              .synchronizers([
                               MockBuilder.new(mock_primary),
                MockBuilder.new(mock_secondary),
                             ])
              .fdv1_compatible_synchronizer(td_fdv1.test_data_ds_builder)
              .build

            fdv2 = FDv2.new(sdk_key, config, data_system_config)

            ready_event = fdv2.start
            expect(ready_event.wait(2)).to be true

            # Give it a moment to process
            sleep 0.5

            # The primary should have been called, then secondary
            expect(mock_primary).to have_received(:sync)
            expect(mock_secondary).to have_received(:sync)

            fdv2.stop
          end
        end

        describe "stays on FDv1 after fallback" do
          it "does not retry FDv2 after falling back to FDv1" do
            mock_primary = double("primary_synchronizer")
            allow(mock_primary).to receive(:name).and_return("mock-primary")
            allow(mock_primary).to receive(:stop)

            update = LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
              revert_to_fdv1: true
            )
            allow(mock_primary).to receive(:sync).and_yield(update)

            # Create FDv1 fallback
            td_fdv1 = LaunchDarkly::Integrations::TestDataV2.data_source
            td_fdv1.update(td_fdv1.flag("fdv1flag").on(true))

            data_system_config = LaunchDarkly::DataSystem::ConfigBuilder.new
              .initializers(nil)
              .synchronizers([MockBuilder.new(mock_primary)])
              .fdv1_compatible_synchronizer(td_fdv1.test_data_ds_builder)
              .build

            fdv2 = FDv2.new(sdk_key, config, data_system_config)

            ready_event = fdv2.start
            expect(ready_event.wait(2)).to be true

            # Give it time to settle
            sleep 1.0

            # Primary should only be called once (not retried after fallback)
            expect(mock_primary).to have_received(:sync).once

            # Verify FDv1 is serving data
            store = fdv2.store
            flag = store.get(LaunchDarkly::Impl::DataStore::FEATURES, :fdv1flag)
            expect(flag).not_to be_nil

            fdv2.stop
          end
        end
      end
    end
  end
end

