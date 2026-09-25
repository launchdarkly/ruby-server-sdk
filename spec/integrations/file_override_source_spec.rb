# frozen_string_literal: true

require "spec_helper"
require "capturing_logger"
require "model_builders"
require "override_test_components"
require "tmpdir"
require "ldclient-rb/integrations/file_data"

module LaunchDarkly
  module Integrations
    describe "FileData.override_source" do
      # Records every snapshot the source supplies.
      class RecordingSink
        include Interfaces::Overrides::OverrideSink

        def initialize
          @lock = Mutex.new
          @snapshots = []
        end

        def set_overrides(flags, segments)
          @lock.synchronize { @snapshots << [flags, segments] }
        end

        def snapshots
          @lock.synchronize { @snapshots.dup }
        end

        def flag_values(index = -1)
          snapshots[index][0].to_h { |flag| [flag.key, flag.variations[0]] }
        end

        def segment_keys(index = -1)
          snapshots[index][1].map(&:key)
        end
      end

      around do |example|
        Dir.mktmpdir do |dir|
          @dir = dir
          example.run
        end
      end

      let(:logger) { CapturingLogger.new }
      let(:config) { Config.new(logger: logger) }

      def path(name)
        File.join(@dir, name)
      end

      def write(name, content)
        File.write(path(name), content)
        path(name)
      end

      def values_doc(values)
        { flagValues: values }.to_json
      end

      def wait_for(timeout = 5)
        deadline = Time.now + timeout
        until yield
          return false if Time.now > deadline
          sleep 0.02
        end
        true
      end

      def build(options)
        FileData.override_source(options).build("sdk-key", config)
      end

      # Builds the source directly so that tests can use a short polling interval.
      def make_source(paths, duplicate_keys_handling: :fail, change_detection: :polling, poll_interval: 0.05)
        Impl::Integrations::FileOverrideSource.new(
          paths: Impl::FileData.absolute_paths(paths),
          duplicate_keys_handling: duplicate_keys_handling,
          change_detection: change_detection,
          poll_interval: poll_interval,
          logger: logger
        )
      end

      def with_source(paths, **options)
        source = make_source(paths, **options)
        sink = RecordingSink.new
        source.start(sink)
        begin
          yield source, sink
        ensure
          source.stop
        end
      end

      describe "builder" do
        it "builds a polling source with the default options and absolute paths" do
          source = build(paths: ["relative.json"])

          expect(source).to be_a(Interfaces::Overrides::OverrideSource)
          expect(source.paths).to eq [File.absolute_path("relative.json")]
          expect(source.duplicate_keys_handling).to eq :fail
          expect(source.change_detection).to eq :polling
          expect(source.poll_interval).to eq 1
        end

        it "accepts a single path string and explicit options" do
          source = build(paths: "one.json", duplicate_keys_handling: :ignore, poll_interval: 2.5)

          expect(source.paths).to eq [File.absolute_path("one.json")]
          expect(source.duplicate_keys_handling).to eq :ignore
          expect(source.poll_interval).to eq 2.5
        end

        it "rejects a configuration with no file paths" do
          expect { build({}) }.to raise_error(ArgumentError, /no file paths/)
          expect { build(paths: []) }.to raise_error(ArgumentError, /no file paths/)
          expect { build(paths: nil) }.to raise_error(ArgumentError, /no file paths/)
        end

        it "rejects options that are not a hash and unknown option keys" do
          expect { FileData.override_source("x") }.to raise_error(ArgumentError, /must be a Hash/)
          expect { build(paths: ["a.json"], path: "b.json") }.to raise_error(ArgumentError, /unknown options.*path/)
        end

        it "rejects an unrecognized duplicate keys handling" do
          expect { build(paths: ["a.json"], duplicate_keys_handling: :first) }.to raise_error(ArgumentError, /duplicate keys handling/)
          expect { build(paths: ["a.json"], duplicate_keys_handling: "fail") }.to raise_error(ArgumentError, /duplicate keys handling/)
        end

        it "rejects an unrecognized change detection mode" do
          expect { build(paths: ["a.json"], change_detection: :notify) }.to raise_error(ArgumentError, /change detection/)
        end

        it "rejects watching when the listen gem is not available" do
          allow(Impl::FileData::Watcher).to receive(:available?).and_return(false)

          expect { build(paths: ["a.json"], change_detection: :watching) }.to raise_error(ArgumentError, /listen gem/)
        end

        it "builds a watching source when the listen gem is available" do
          allow(Impl::FileData::Watcher).to receive(:available?).and_return(true)

          expect(build(paths: ["a.json"], change_detection: :watching).change_detection).to eq :watching
        end

        it "rejects a poll interval that is not a number" do
          expect { build(paths: ["a.json"], poll_interval: "1") }.to raise_error(ArgumentError, /poll interval/)
        end

        it "raises a poll interval below the minimum to the minimum with a warning" do
          source = build(paths: ["a.json"], poll_interval: 0.1)

          expect(source.poll_interval).to eq 1
          expect(logger.output).to include("Poll interval 0.1s is below the minimum")
        end

        it "does not warn about the poll interval in watching mode" do
          allow(Impl::FileData::Watcher).to receive(:available?).and_return(true)

          build(paths: ["a.json"], change_detection: :watching, poll_interval: 0.1)

          expect(logger.output).not_to include("below the minimum")
        end
      end

      describe "initial load" do
        it "supplies the merged files to the sink before start returns" do
          a = write("a.json", values_doc({ flag1: "a" }))
          b = write("b.json", { flags: { flag2: { key: "flag2", on: false, offVariation: 0, variations: ["b"] } },
                                segments: { seg1: { key: "seg1", included: ["user"] } } }.to_json)

          with_source([a, b]) do |_source, sink|
            expect(sink.snapshots.length).to eq 1
            expect(sink.flag_values).to eq({ "flag1" => "a", "flag2" => "b" })
            expect(sink.segment_keys).to eq ["seg1"]
          end
        end

        it "expands a flag value into a flag that is off and serves the value" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_source([a]) do |_source, sink|
            flag = sink.snapshots[0][0][0]
            expect(flag.on).to be false
            expect(flag.off_variation).to eq 0
            expect(flag.off_result.reason).to eq EvaluationReason.off
          end
        end

        it "reads YAML files" do
          a = write("a.yaml", "flagValues:\n  yaml-flag: \"override-value\"\n")

          with_source([a]) do |_source, sink|
            expect(sink.flag_values).to eq({ "yaml-flag" => "override-value" })
          end
        end

        it "treats a configured file that does not exist as contributing no overrides" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_source([a, path("missing.json")]) do |_source, sink|
            expect(sink.snapshots.length).to eq 1
            expect(sink.flag_values).to eq({ "flag1" => "a" })
            expect(logger.output).not_to include("ERROR")
          end
        end

        it "supplies an empty snapshot when no configured file exists" do
          with_source([path("missing.json")]) do |_source, sink|
            expect(sink.snapshots).to eq [[[], []]]
          end
        end

        it "fails the load and logs when a file cannot be parsed, leaving the sink untouched" do
          a = write("a.json", '{"flagValues"')

          with_source([a]) do |_source, sink|
            expect(sink.snapshots).to be_empty
            expect(logger.output).to include("ERROR")
            expect(logger.output).to include("FileOverrideSource: Unable to load flags")
          end
        end

        it "fails the load when a key appears in two files with the default handling" do
          a = write("a.json", values_doc({ flag1: "first" }))
          b = write("b.json", values_doc({ flag1: "second" }))

          with_source([a, b]) do |_source, sink|
            expect(sink.snapshots).to be_empty
            expect(logger.output).to include("was used more than once")
          end
        end

        it "keeps the first file's entry with ignore handling" do
          a = write("a.json", values_doc({ flag1: "first" }))
          b = write("b.json", values_doc({ flag1: "second", flag2: "other" }))

          with_source([a, b], duplicate_keys_handling: :ignore) do |_source, sink|
            expect(sink.flag_values).to eq({ "flag1" => "first", "flag2" => "other" })
          end
        end
      end

      describe "logging" do
        it "logs the overrides in effect and what each file supplied" do
          a = write("a.json", { flagValues: { flag1: "a", flag2: "b" }, segments: { seg1: { key: "seg1" } } }.to_json)
          b = write("b.json", "{}")
          missing = path("missing.json")

          with_source([a, b, missing]) do |_source, _sink|
            expect(logger.output).to include(
              "INFO -- : [LDClient] FileOverrideSource: Flag overrides in effect: 2 flags, 1 segment " \
              "(#{a}: 2 flags, 1 segment; #{b}: no entries; #{missing}: absent)"
            )
          end
        end

        it "logs when no overrides are in effect" do
          a = write("a.json", "{}")

          with_source([a]) do |_source, _sink|
            expect(logger.output).to include("Flag overrides: none in effect (#{a}: no entries)")
          end
        end
      end

      describe "polling change detection" do
        it "applies a changed file" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_source([a]) do |_source, sink|
            sleep 0.1
            write("a.json", values_doc({ flag1: "b" }))

            expect(wait_for { sink.snapshots.length == 2 }).to be true
            expect(sink.flag_values).to eq({ "flag1" => "b" })
          end
        end

        it "applies a file that appears after start" do
          with_source([path("later.json")]) do |_source, sink|
            expect(sink.snapshots.length).to eq 1
            write("later.json", values_doc({ flag1: "a" }))

            expect(wait_for { sink.snapshots.length == 2 }).to be true
            expect(sink.flag_values).to eq({ "flag1" => "a" })
          end
        end

        it "removes the overrides of a deleted file" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_source([a]) do |_source, sink|
            File.delete(a)

            expect(wait_for { sink.snapshots.length == 2 }).to be true
            expect(sink.snapshots[-1]).to eq [[], []]
          end
        end

        it "keeps the last good overrides through a malformed edit and recovers" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_source([a]) do |_source, sink|
            write("a.json", '{"flagValues"')
            sleep 0.5
            expect(sink.snapshots.length).to eq 1
            expect(logger.output).to include("Unable to load flags")

            write("a.json", values_doc({ flag1: "c" }))
            expect(wait_for { sink.snapshots.length == 2 }).to be true
            expect(sink.flag_values).to eq({ "flag1" => "c" })
          end
        end

        it "does not supply a snapshot for a rewrite with identical content" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_source([a]) do |_source, sink|
            sleep 0.1
            File.utime(Time.now + 5, Time.now + 5, a)
            sleep 0.5

            expect(sink.snapshots.length).to eq 1
          end
        end

        it "stops detecting changes when stopped" do
          a = write("a.json", values_doc({ flag1: "a" }))
          source = make_source([a])
          sink = RecordingSink.new
          source.start(sink)
          poller_threads = Thread.list.select { |t| t.name == "LD/FileDataPoller" }
          expect(poller_threads.length).to eq 1

          source.stop

          expect(poller_threads[0].alive?).to be false
          write("a.json", values_doc({ flag1: "b" }))
          sleep 0.5
          expect(sink.snapshots.length).to eq 1
        end

        it "does not start when stopped before start" do
          a = write("a.json", values_doc({ flag1: "a" }))
          source = make_source([a])
          sink = RecordingSink.new
          source.stop
          source.start(sink)

          expect(sink.snapshots).to be_empty
        end
      end

      describe "watching change detection" do
        before do
          skip "the listen gem is not installed" unless Impl::FileData::Watcher.available?
        end

        it "applies a changed file" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_source([a], change_detection: :watching) do |_source, sink|
            sleep 0.3
            write("a.json", values_doc({ flag1: "b" }))

            expect(wait_for { sink.snapshots.length == 2 }).to be true
            expect(sink.flag_values).to eq({ "flag1" => "b" })
          end
        end

        it "applies a file that appears after start" do
          with_source([path("later.json")], change_detection: :watching) do |_source, sink|
            sleep 0.3
            write("later.json", values_doc({ flag1: "a" }))

            expect(wait_for { sink.snapshots.length == 2 }).to be true
            expect(sink.flag_values).to eq({ "flag1" => "a" })
          end
        end

        it "removes the overrides of a deleted file" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_source([a], change_detection: :watching) do |_source, sink|
            sleep 0.3
            File.delete(a)

            expect(wait_for { sink.snapshots.length == 2 }).to be true
            expect(sink.snapshots[-1]).to eq [[], []]
          end
        end
      end

      describe "with a client" do
        let(:context) { LDContext.create({ key: "user-key", kind: "user" }) }
        let(:ld_flag) { { key: "flag", version: 100, on: false, offVariation: 0, variations: ["ld-value"] } }

        def with_client(overrides)
          data_system = DataSystem.custom
            .initializers([TestDataInitializer.new(flags: { flag: ld_flag })])
            .overrides(overrides)
            .build
          client = LDClient.new("sdk-key", Config.new(data_system_config: data_system, send_events: false, logger: logger), 5)
          begin
            yield client
          ensure
            client.close
          end
        end

        it "serves overrides from the files and reloads them on a running client" do
          a = write("a.json", values_doc({ flag: "override-value", other: true }))
          overrides = FileData.override_source(paths: [a])

          with_client(overrides) do |client|
            detail = client.variation_detail("flag", context, "default")
            expect(detail.value).to eq "override-value"
            expect(detail.reason).to eq EvaluationReason.off.with_override_affected(true)
            expect(client.variation("other", context, false)).to be true

            write("a.json", "{}")
            expect(wait_for { client.variation("flag", context, "default") == "ld-value" }).to be true
            expect(client.variation("other", context, false)).to be false
          end
        end

        it "reports invalid options from client construction" do
          data_system = DataSystem.custom.overrides(FileData.override_source(paths: [])).build

          expect { LDClient.new("sdk-key", Config.new(data_system_config: data_system, send_events: false, logger: logger), 0) }
            .to raise_error(ArgumentError, /no file paths/)
        end
      end
    end
  end
end
