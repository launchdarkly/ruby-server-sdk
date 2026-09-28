require "spec_helper"
require "capturing_logger"
require "tempfile"
require "ldclient-rb/integrations/file_data"

#
# These specs pin behaviors of the existing file data sources that their other specs do not
# assert. The file-based override source shares the document format but not the implementation,
# and these sources must keep behaving as they always have.
#
module LaunchDarkly
  module Integrations
    describe "file data source behavior" do
      let(:logger) { CapturingLogger.new }

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

      def wait_for(timeout = 5)
        deadline = Time.now + timeout
        until yield
          return false if Time.now > deadline
          sleep 0.05
        end
        true
      end

      def flag_json(key, version: nil)
        data = { key: key, on: true, fallthrough: { variation: 0 }, variations: ["a"] }
        data[:version] = version unless version.nil?
        data
      end

      describe FileData, "data_source" do
        # Counts every init call so that a test can see each reload.
        class CountingFeatureStore < InMemoryFeatureStore
          attr_reader :init_count

          def initialize
            super
            @init_count = 0
          end

          def init(all_data)
            @init_count += 1
            super
          end
        end

        before do
          @store = CountingFeatureStore.new
          @config = LaunchDarkly::Config.new(logger: logger, feature_store: @store)
          executor = SynchronousExecutor.new
          @status_broadcaster = LaunchDarkly::Impl::Broadcaster.new(executor, logger)
          @flag_change_broadcaster = LaunchDarkly::Impl::Broadcaster.new(executor, logger)
          @config.data_source_update_sink = LaunchDarkly::Impl::DataSource::UpdateSink.new(@store, @status_broadcaster, @flag_change_broadcaster)
        end

        def with_data_source(options)
          ds = FileData.data_source(options).call('', @config)
          begin
            yield ds
          ensure
            ds.stop
          end
        end

        def flag_version(key)
          @store.get(Impl::DataStore::FEATURES, key).version
        end

        def status
          @config.data_source_update_sink.current_status
        end

        it "numbers versions per file in load order and keeps counting across reloads" do
          file1 = make_temp_file({ flags: { flag1: flag_json("flag1", version: 99) }, flagValues: { value1: true } }.to_json)
          file2 = make_temp_file({ segments: { seg1: { key: "seg1" } } }.to_json)

          with_data_source({ paths: [file1.path, file2.path], auto_update: true, force_polling: true, poll_interval: 0.1 }) do |ds|
            ds.start
            expect(flag_version("flag1")).to eq 1
            expect(flag_version("value1")).to eq 1
            expect(@store.get(Impl::DataStore::SEGMENTS, "seg1").version).to eq 2

            sleep 0.2
            IO.write(file2, { segments: { seg1: { key: "seg1" }, seg2: { key: "seg2" } } }.to_json)
            expect(wait_for { @store.get(Impl::DataStore::SEGMENTS, "seg2") }).to be true
            expect(flag_version("flag1")).to eq 3
            expect(@store.get(Impl::DataStore::SEGMENTS, "seg2").version).to eq 4
          end
        end

        it "stores an item under its own key member rather than the key it appears under" do
          file = make_temp_file({ flags: { "map-key": flag_json("own-key") } }.to_json)

          with_data_source({ paths: [file.path] }) do |ds|
            ds.start
            expect(@store.get(Impl::DataStore::FEATURES, "own-key")).not_to be_nil
            expect(@store.get(Impl::DataStore::FEATURES, "map-key")).to be_nil
          end
        end

        it "expands a flag value into a flag that is on and serves the value through its fallthrough" do
          file = make_temp_file({ flagValues: { value1: "x" } }.to_json)

          with_data_source({ paths: [file.path] }) do |ds|
            ds.start
            flag = @store.get(Impl::DataStore::FEATURES, "value1")
            expect(flag.on).to be true
            expect(flag.fallthrough.variation).to eq 0
            expect(flag.off_variation).to be_nil
            expect(flag.variations).to eq ["x"]
          end
        end

        it "does not retry a failed initial load on its own" do
          file = make_temp_file('{"flagValues"')

          with_data_source({ paths: [file.path] }) do |ds|
            ds.start
            expect(ds.initialized?).to be false
            IO.write(file, { flagValues: { value1: "x" } }.to_json)
            sleep 1.5

            expect(ds.initialized?).to be false
            expect(@store.init_count).to eq 0
          end
        end

        it "logs a failed load with the file path at error level" do
          file = make_temp_file('{"flagValues"')

          with_data_source({ paths: [file.path] }) do |ds|
            ds.start
            expect(logger.output).to match(/ERROR -- : \[LDClient\] Unable to load flag data from "#{Regexp.escape(file.path)}": /)
            expect(status.state).to eq Interfaces::DataSource::Status::INITIALIZING
            expect(status.last_error.kind).to eq Interfaces::DataSource::ErrorInfo::INVALID_DATA
          end
        end

        it "treats a missing file as a failed load with the same message" do
          missing = File.join(@tmp_dir, "no-such-file.json")

          with_data_source({ paths: [missing] }) do |ds|
            ds.start
            expect(ds.initialized?).to be false
            expect(logger.output).to include("Unable to load flag data from \"#{missing}\"")
          end
        end

        it "reports a duplicate key with the data kind namespace" do
          file1 = make_temp_file({ flags: { flag1: flag_json("flag1") } }.to_json)
          file2 = make_temp_file({ flagValues: { flag1: "x" } }.to_json)

          with_data_source({ paths: [file1.path, file2.path] }) do |ds|
            ds.start
            expect(logger.output).to include('features key "flag1" was used more than once')
            expect(@store.init_count).to eq 0
          end
        end

        it "compares only the modification time when polling" do
          file = make_temp_file({ flagValues: { value1: "x" } }.to_json)

          with_data_source({ paths: [file.path], auto_update: true, force_polling: true, poll_interval: 0.1 }) do |ds|
            ds.start
            mtime = File.mtime(file.path)
            IO.write(file, { flagValues: { value1: "a much longer value than before" } }.to_json)
            File.utime(mtime, mtime, file.path)
            sleep 0.5

            expect(@store.init_count).to eq 1
          end
        end

        it "does not react to a deleted file when polling" do
          file = make_temp_file({ flagValues: { value1: "x" } }.to_json)

          with_data_source({ paths: [file.path], auto_update: true, force_polling: true, poll_interval: 0.1 }) do |ds|
            ds.start
            File.delete(file.path)
            sleep 0.5

            expect(@store.init_count).to eq 1
            expect(status.state).to eq Interfaces::DataSource::Status::VALID
            expect(@store.get(Impl::DataStore::FEATURES, "value1")).not_to be_nil
          end
        end

        it "reloads on every polling interval after the first change" do
          file = make_temp_file({ flagValues: { value1: "x" } }.to_json)

          with_data_source({ paths: [file.path], auto_update: true, force_polling: true, poll_interval: 0.1 }) do |ds|
            ds.start
            sleep 0.2
            IO.write(file, { flagValues: { value1: "y" } }.to_json)
            expect(wait_for { @store.init_count >= 2 }).to be true

            expect(wait_for { @store.init_count >= 4 }).to be true
          end
        end

        it "uses the listen gem for auto-update when it is available" do
          skip "the listen gem is not installed" unless defined?(Listen)

          file = make_temp_file({ flagValues: { value1: "x" } }.to_json)
          expect(Listen).to receive(:to).and_call_original

          with_data_source({ paths: [file.path], auto_update: true }) do |ds|
            ds.start
          end
        end

        it "does not use the listen gem when polling is forced" do
          file = make_temp_file({ flagValues: { value1: "x" } }.to_json)
          expect(Listen).not_to receive(:to) if defined?(Listen)

          with_data_source({ paths: [file.path], auto_update: true, force_polling: true, poll_interval: 0.1 }) do |ds|
            ds.start
            expect(Thread.list.map(&:name)).to include("LD/FileDataSource")
          end
        end
      end

      describe Impl::Integrations::FileDataSourceV2 do
        def no_selector_store
          store = Object.new
          store.define_singleton_method(:selector) { Interfaces::DataSystem::Selector.no_selector }
          store
        end

        def fetch_changes(paths)
          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: paths)
          begin
            result = source.fetch(no_selector_store)
            expect(result.success?).to be true
            result.value.change_set.changes
          ensure
            source.stop
          end
        end

        def without_listen
          klass = Impl::Integrations::FileDataSourceV2
          had_listen = klass.class_variable_get(:@@have_listen)
          klass.class_variable_set(:@@have_listen, false)
          begin
            yield
          ensure
            klass.class_variable_set(:@@have_listen, had_listen)
          end
        end

        def with_sync(paths, poll_interval: 0.1)
          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: paths, poll_interval: poll_interval)
          updates = Queue.new
          thread = Thread.new { source.sync(no_selector_store) { |update| updates << update } }
          begin
            initial = updates.pop(timeout: 5)
            expect(initial).not_to be_nil
            expect(initial.state).to eq Interfaces::DataSource::Status::VALID
            yield updates
          ensure
            source.stop
            thread.join(2)
          end
        end

        it "defaults a missing version to 1 and keeps a given version" do
          file = make_temp_file({ flags: { flag1: flag_json("flag1"), flag2: flag_json("flag2", version: 7) },
                                  flagValues: { value1: "x" }, segments: { seg1: { key: "seg1" } } }.to_json)

          versions = fetch_changes([file.path]).to_h { |change| [change.key, change.version] }

          expect(versions).to eq({ flag1: 1, flag2: 7, value1: 1, seg1: 1 })
        end

        it "expands a flag value into a flag that is on and serves the value through its fallthrough" do
          file = make_temp_file({ flagValues: { value1: "x" } }.to_json)

          change = fetch_changes([file.path]).detect { |c| c.key == :value1 }
          expect(change.object[:on]).to be true
          expect(change.object[:fallthrough]).to eq({ variation: 0 })
          expect(change.object).not_to have_key(:offVariation)
          expect(change.object[:variations]).to eq ["x"]
        end

        it "stores an item under its own key member rather than the key it appears under" do
          file = make_temp_file({ flags: { "map-key": flag_json("own-key") } }.to_json)

          expect(fetch_changes([file.path]).map(&:key)).to eq [:"own-key"]
        end

        it "reports a failed load with the file path" do
          file = make_temp_file('{"flagValues"')
          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file.path])
          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to be false
            expect(result.error).to start_with("Unable to load flag data from \"#{file.path}\": ")
            expect(logger.output).to match(/ERROR -- : \[LDClient\] Unable to load flag data from "#{Regexp.escape(file.path)}": /)
          ensure
            source.stop
          end
        end

        it "reports a duplicate key with the section name" do
          file1 = make_temp_file({ flags: { flag1: flag_json("flag1") } }.to_json)
          file2 = make_temp_file({ flagValues: { flag1: "x" } }.to_json)
          source = Impl::Integrations::FileDataSourceV2.new(logger, paths: [file1.path, file2.path])
          begin
            result = source.fetch(no_selector_store)

            expect(result.success?).to be false
            expect(result.error).to include('In flags, key "flag1" was used more than once')
          ensure
            source.stop
          end
        end

        it "uses the listen gem for change detection when it is available" do
          skip "the listen gem is not installed" unless defined?(Listen)

          file = make_temp_file({ flagValues: { value1: "x" } }.to_json)
          expect(Listen).to receive(:to).and_call_original

          with_sync([file.path]) { |_updates| }
        end

        it "compares only the modification time when polling" do
          without_listen do
            file = make_temp_file({ flagValues: { value1: "x" } }.to_json)

            with_sync([file.path]) do |updates|
              mtime = File.mtime(file.path)
              IO.write(file, { flagValues: { value1: "a much longer value than before" } }.to_json)
              File.utime(mtime, mtime, file.path)

              expect(updates.pop(timeout: 0.6)).to be_nil
            end
          end
        end

        it "does not react to a deleted file when polling" do
          without_listen do
            file = make_temp_file({ flagValues: { value1: "x" } }.to_json)

            with_sync([file.path]) do |updates|
              File.delete(file.path)

              expect(updates.pop(timeout: 0.6)).to be_nil
            end
          end
        end

        it "reloads once per change when polling" do
          without_listen do
            file = make_temp_file({ flagValues: { value1: "x" } }.to_json)

            with_sync([file.path]) do |updates|
              sleep 0.2
              IO.write(file, { flagValues: { value1: "y" } }.to_json)

              update = updates.pop(timeout: 5)
              expect(update).not_to be_nil
              expect(update.state).to eq Interfaces::DataSource::Status::VALID
              expect(updates.pop(timeout: 0.6)).to be_nil
            end
          end
        end
      end
    end
  end
end
