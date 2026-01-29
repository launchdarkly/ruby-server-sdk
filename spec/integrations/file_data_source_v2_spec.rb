# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "ldclient-rb/impl/integrations/file_data_source_v2"
require "ldclient-rb/integrations/file_data"
require "ldclient-rb/interfaces/data_system"

module LaunchDarkly
  module Integrations
    RSpec.describe "FileDataSourceV2" do
      let(:logger) { $null_log }

      let(:all_properties_json) { <<-EOF
{
  "flags": {
    "flag1": {
      "key": "flag1",
      "on": true,
      "fallthrough": {
        "variation": 2
      },
      "variations": [ "fall", "off", "on" ]
    }
  },
  "flagValues": {
    "flag2": "value2"
  },
  "segments": {
    "seg1": {
      "key": "seg1",
      "include": ["user1"]
    }
  }
}
EOF
      }

      let(:all_properties_yaml) { <<-EOF
---
flags:
  flag1:
    key: flag1
    "on": true
flagValues:
  flag2: value2
segments:
  seg1:
    key: seg1
    include: ["user1"]
EOF
      }

      let(:flag_only_json) { <<-EOF
{
  "flags": {
    "flag1": {
      "key": "flag1",
      "on": true,
      "fallthrough": {
        "variation": 2
      },
      "variations": [ "fall", "off", "on" ]
    }
  }
}
EOF
      }

      let(:segment_only_json) { <<-EOF
{
  "segments": {
    "seg1": {
      "key": "seg1",
      "include": ["user1"]
    }
  }
}
EOF
      }

      let(:flag_values_only_json) { <<-EOF
{
  "flagValues": {
    "flag2": "value2"
  }
}
EOF
      }

      class MockSelectorStore
        include LaunchDarkly::Interfaces::DataSystem::SelectorStore

        def initialize(selector)
          @selector = selector
        end

        def selector
          @selector
        end
      end

      before do
        @tmp_dir = Dir.mktmpdir
      end

      after do
        FileUtils.rm_rf(@tmp_dir)
      end

      def make_temp_file(content)
        file = Tempfile.new('flags', @tmp_dir)
        IO.write(file, content)
        file
      end

      def no_selector_store
        MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)
      end

      describe "initializer (fetch)" do
        it "creates valid initializer" do
          file = make_temp_file(all_properties_json)

          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file.path])

          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to eq(true)

            basis = result.value
            expect(basis.persist).to eq(false)
            expect(basis.environment_id).to be_nil
            expect(basis.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)

            # Should have 2 flags and 1 segment
            changes = basis.change_set.changes
            expect(changes.length).to eq(3)

            flag_changes = changes.select { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG }
            segment_changes = changes.select { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT }

            expect(flag_changes.length).to eq(2)
            expect(segment_changes.length).to eq(1)

            # Check selector is no_selector
            expect(basis.change_set.selector).to eq(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)
          ensure
            source.stop
          end
        end

        it "handles missing file" do
          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: ['no-such-file.json'])

          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to eq(false)
            expect(result.error).to include("no-such-file.json")
          ensure
            source.stop
          end
        end

        it "handles invalid JSON" do
          file = make_temp_file('{"flagValues":{')

          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file.path])

          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to eq(false)
            expect(result.error).to include("Unable to load flag data")
          ensure
            source.stop
          end
        end

        it "handles duplicate keys" do
          file1 = make_temp_file(flag_only_json)
          file2 = make_temp_file(flag_only_json)

          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file1.path, file2.path])

          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to eq(false)
            expect(result.error).to include("was used more than once")
          ensure
            source.stop
          end
        end

        it "loads multiple files" do
          file1 = make_temp_file(flag_only_json)
          file2 = make_temp_file(segment_only_json)

          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file1.path, file2.path])

          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to eq(true)

            changes = result.value.change_set.changes
            flag_changes = changes.select { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG }
            segment_changes = changes.select { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT }

            expect(flag_changes.length).to eq(1)
            expect(segment_changes.length).to eq(1)
          ensure
            source.stop
          end
        end

        it "loads YAML" do
          file = make_temp_file(all_properties_yaml)

          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file.path])

          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to eq(true)
            expect(result.value.change_set.changes.length).to eq(3) # 2 flags + 1 segment
          ensure
            source.stop
          end
        end

        it "handles flag values" do
          file = make_temp_file(flag_values_only_json)

          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file.path])

          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to eq(true)

            changes = result.value.change_set.changes
            flag_changes = changes.select { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG }
            expect(flag_changes.length).to eq(1)

            # Check the flag was created with the expected structure
            flag_change = flag_changes[0]
            expect(flag_change.key).to eq(:flag2)
            expect(flag_change.object[:key]).to eq("flag2")
            expect(flag_change.object[:on]).to eq(true)
            expect(flag_change.object[:variations]).to eq(["value2"])
          ensure
            source.stop
          end
        end
      end

      describe "synchronizer (sync)" do
        it "creates valid synchronizer" do
          file = make_temp_file(all_properties_json)

          source = Impl::Integrations::FileDataSourceV2.new(
            logger,
            paths: [file.path],
            poll_interval: 0.1
          )

          updates = []

          begin
            sync_thread = Thread.new do
              source.sync(no_selector_store) do |update|
                updates << update
                break if updates.length >= 1
              end
            end

            # Wait for initial update with timeout
            deadline = Time.now + 5
            while updates.empty? && Time.now < deadline
              sleep 0.1
            end

            expect(updates.length).to be >= 1
            expect(updates[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
            expect(updates[0].change_set).not_to be_nil
            expect(updates[0].change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            expect(updates[0].change_set.changes.length).to eq(3)
          ensure
            source.stop
            sync_thread&.join(2)
          end
        end

        it "detects file changes" do
          file = make_temp_file(flag_only_json)

          source = Impl::Integrations::FileDataSourceV2.new(
            logger,
            paths: [file.path],
            poll_interval: 0.1
          )

          updates = []
          update_received = Concurrent::Event.new

          begin
            sync_thread = Thread.new do
              source.sync(no_selector_store) do |update|
                updates << update
                update_received.set
                break if updates.length >= 2
              end
            end

            # Wait for initial update
            expect(update_received.wait(5)).to eq(true), "Did not receive initial update"
            expect(updates.length).to eq(1)
            expect(updates[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)

            initial_flags = updates[0].change_set.changes.select { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG }
            expect(initial_flags.length).to eq(1)

            # Modify the file
            update_received.reset
            sleep 0.2 # Ensure filesystem timestamp changes
            IO.write(file, segment_only_json)

            # Wait for the change to be detected
            expect(update_received.wait(5)).to eq(true), "Did not receive update after file change"
            expect(updates.length).to eq(2)
            expect(updates[1].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)

            segment_changes = updates[1].change_set.changes.select { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT }
            expect(segment_changes.length).to eq(1)
          ensure
            source.stop
            sync_thread&.join(2)
          end
        end

        it "reports error on invalid file update" do
          file = make_temp_file(flag_only_json)

          source = Impl::Integrations::FileDataSourceV2.new(
            logger,
            paths: [file.path],
            poll_interval: 0.1
          )

          updates = []
          update_received = Concurrent::Event.new

          begin
            sync_thread = Thread.new do
              source.sync(no_selector_store) do |update|
                updates << update
                update_received.set
                break if updates.length >= 2
              end
            end

            # Wait for initial update
            expect(update_received.wait(5)).to eq(true), "Did not receive initial update"
            expect(updates.length).to eq(1)
            expect(updates[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)

            # Make the file invalid
            update_received.reset
            sleep 0.2 # Ensure filesystem timestamp changes
            IO.write(file, '{"invalid json')

            # Wait for the error to be detected
            expect(update_received.wait(5)).to eq(true), "Did not receive update after file became invalid"
            expect(updates.length).to eq(2)
            expect(updates[1].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
            expect(updates[1].error).not_to be_nil
          ensure
            source.stop
            sync_thread&.join(2)
          end
        end

        it "can be stopped" do
          file = make_temp_file(all_properties_json)

          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file.path])

          updates = []

          sync_thread = Thread.new do
            source.sync(no_selector_store) do |update|
              updates << update
            end
          end

          # Give it a moment to process initial data
          sleep 0.3

          # Stop it
          source.stop

          # Thread should complete
          sync_thread.join(2)
          expect(sync_thread.alive?).to eq(false)

          # Should have received at least the initial update
          expect(updates.length).to be >= 1
          expect(updates[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
        end
      end

      describe "fetch after stop" do
        it "returns error" do
          file = make_temp_file(all_properties_json)

          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file.path])

          # First fetch should work
          result = source.fetch(no_selector_store)
          expect(result.success?).to eq(true)

          # Stop the source
          source.stop

          # Second fetch should fail
          result = source.fetch(no_selector_store)
          expect(result.success?).to eq(false)
          expect(result.error).to include("closed")
        end
      end

      describe "name property" do
        it "returns correct name" do
          file = make_temp_file(all_properties_json)

          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file.path])

          begin
            expect(source.name).to eq("FileDataV2")
          ensure
            source.stop
          end
        end
      end

      describe "accepts single path string" do
        it "works with string instead of array" do
          file = make_temp_file(flag_only_json)

          # Pass a single string instead of a list
          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: file.path)

          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to eq(true)
            expect(result.value.change_set.changes.length).to eq(1)
          ensure
            source.stop
          end
        end
      end

      describe "public API (data_source_v2)" do
        it "creates builder that works as initializer" do
          file = make_temp_file(all_properties_json)

          builder = FileData.data_source_v2(paths: [file.path])
          config = LaunchDarkly::Config.new(logger: logger)

          source = builder.build('sdk-key', config)

          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to eq(true)
            expect(result.value.change_set.changes.length).to eq(3)
          ensure
            source.stop
          end
        end

        it "creates builder that works as synchronizer" do
          file = make_temp_file(all_properties_json)

          builder = FileData.data_source_v2(paths: [file.path], poll_interval: 0.1)
          config = LaunchDarkly::Config.new(logger: logger)

          source = builder.build('sdk-key', config)

          updates = []

          begin
            sync_thread = Thread.new do
              source.sync(no_selector_store) do |update|
                updates << update
                break if updates.length >= 1
              end
            end

            deadline = Time.now + 5
            while updates.empty? && Time.now < deadline
              sleep 0.1
            end

            expect(updates.length).to be >= 1
            expect(updates[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
          ensure
            source.stop
            sync_thread&.join(2)
          end
        end
      end
    end
  end
end
