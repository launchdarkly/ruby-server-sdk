# frozen_string_literal: true

require "spec_helper"
require "capturing_logger"
require "tmpdir"
require "ldclient-rb/impl/file_data"

module LaunchDarkly
  module Impl
    module FileData
      describe Reloader do
        around do |example|
          Dir.mktmpdir do |dir|
            @dir = dir
            example.run
          end
        end

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

        def wait_for(timeout = 3)
          deadline = Time.now + timeout
          until yield
            return false if Time.now > deadline
            sleep 0.01
          end
          true
        end

        # Collects apply and on_error calls in a thread-safe way.
        class Recorder
          attr_reader :applied, :errors

          def initialize
            @lock = Mutex.new
            @applied = []
            @errors = []
          end

          def apply(merged)
            @lock.synchronize { @applied << merged }
          end

          def on_error(error)
            @lock.synchronize { @errors << error }
          end

          def flag_values(index = -1)
            @applied[index].flags.transform_values { |flag| flag.variations[0] }
          end
        end

        def make_reloader(paths, recorder, logger: $null_log, **options)
          Reloader.new(paths: paths, logger: logger, apply: recorder.method(:apply), on_error: recorder.method(:on_error), **options)
        end

        def with_reloader(paths, logger: $null_log, **options)
          recorder = Recorder.new
          reloader = make_reloader(paths, recorder, logger: logger, **options)
          begin
            yield reloader, recorder
          ensure
            reloader.stop
          end
        end

        it "does not start a worker thread until it is used" do
          with_reloader([write("a.json", "{}")]) do |reloader, _recorder|
            expect(reloader.instance_variable_get(:@worker)).to be_nil

            reloader.trigger

            worker = reloader.instance_variable_get(:@worker)
            expect(worker).to be_a(Thread)
            expect(worker.name).to eq("LD/FileDataReloader")
          end
        end

        it "applies the merged files and describes each file on a synchronous reload" do
          a = write("a.json", values_doc({ flag1: "a" }))
          b = write("b.json", { flagValues: { flag2: "b" }, segments: { seg1: { key: "seg1" } } }.to_json)

          with_reloader([a, b]) do |reloader, recorder|
            expect(reloader.reload_now).to be true

            expect(recorder.applied.length).to eq(1)
            expect(recorder.flag_values).to eq({ flag1: "a", flag2: "b" })
            expect(recorder.applied[0].segments.keys).to eq([:seg1])
            expected_files = [FileSummary.new(a, true, 1, 0), FileSummary.new(b, true, 1, 1)]
            expect(recorder.applied[0].files).to eq(expected_files)
            expect(recorder.errors).to be_empty
          end
        end

        it "fails a reload for a missing file by default" do
          with_reloader([path("missing.json")], retry_delay: 0) do |reloader, recorder|
            expect(reloader.reload_now).to be false

            expect(recorder.applied).to be_empty
            expect(recorder.errors.length).to eq(1)
            expect(recorder.errors[0]).to be_a(ReadError)
            expect(recorder.errors[0].missing).to be true
          end
        end

        it "treats a missing file as a file with no content when skipping missing paths" do
          a = write("a.json", values_doc({ flag1: "a" }))
          missing = path("missing.json")

          with_reloader([a, missing], skip_missing_paths: true) do |reloader, recorder|
            expect(reloader.reload_now).to be true

            expect(recorder.flag_values).to eq({ flag1: "a" })
            expected_files = [FileSummary.new(a, true, 1, 0), FileSummary.new(missing, false, 0, 0)]
            expect(recorder.applied[0].files).to eq(expected_files)
          end
        end

        it "applies an empty result when every file is missing and missing paths are skipped" do
          with_reloader([path("missing.json")], skip_missing_paths: true) do |reloader, recorder|
            expect(reloader.reload_now).to be true

            expect(recorder.applied.length).to eq(1)
            expect(recorder.applied[0].empty?).to be true
          end
        end

        it "keeps the last good result when a file cannot be parsed and reports the failure once" do
          a = write("a.json", values_doc({ flag1: "a" }))
          logger = CapturingLogger.new

          with_reloader([a], logger: logger, retry_delay: 0) do |reloader, recorder|
            reloader.reload_now
            write("a.json", '{"flagValues"')

            expect(reloader.reload_now).to be false
            expect(reloader.reload_now).to be false

            expect(recorder.applied.length).to eq(1)
            expect(recorder.errors.length).to eq(1)
            expect(recorder.errors[0]).to be_a(ReadError)
            expect(logger.output.scan("ERROR").length).to eq(1)
          end
        end

        it "reports a different failure again" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], retry_delay: 0) do |reloader, recorder|
            write("a.json", '{"flagValues"')
            reloader.reload_now
            write("a.json", '{"flagValues": []}')
            reloader.reload_now

            expect(recorder.errors.length).to eq(2)
          end
        end

        it "fails a reload for duplicate keys across files and applies the first file's entry with ignore handling" do
          a = write("a.json", values_doc({ flag1: "first" }))
          b = write("b.json", values_doc({ flag1: "second" }))

          with_reloader([a, b], retry_delay: 0) do |reloader, recorder|
            expect(reloader.reload_now).to be false
            expect(recorder.errors[0]).to be_a(MergeError)
          end

          with_reloader([a, b], duplicate_keys_handling: DuplicateKeysHandling::IGNORE) do |reloader, recorder|
            expect(reloader.reload_now).to be true
            expect(recorder.flag_values).to eq({ flag1: "first" })
          end
        end

        it "retries a failed reload after the retry delay and recovers when the file is fixed" do
          a = write("a.json", '{"flagValues"')

          with_reloader([a], retry_delay: 0.1) do |reloader, recorder|
            expect(reloader.reload_now).to be false
            write("a.json", values_doc({ flag1: "fixed" }))

            expect(wait_for { recorder.applied.length == 1 }).to be true
            expect(recorder.flag_values).to eq({ flag1: "fixed" })
          end
        end

        it "keeps retrying while the failure persists" do
          a = write("a.json", '{"flagValues"')
          logger = CapturingLogger.new

          with_reloader([a], logger: logger, retry_delay: 0.05) do |reloader, _recorder|
            reloader.reload_now

            expect(wait_for { logger.output.scan("Retrying flag data load").length >= 3 }).to be true
          end
        end

        it "does not retry when the retry delay is zero" do
          a = write("a.json", '{"flagValues"')

          with_reloader([a], retry_delay: 0) do |reloader, recorder|
            reloader.reload_now
            write("a.json", values_doc({ flag1: "fixed" }))
            sleep 0.3

            expect(recorder.applied).to be_empty
          end
        end

        it "coalesces triggers that arrive within the debounce delay into one reload" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], debounce_delay: 0.2) do |reloader, recorder|
            reloader.reload_now
            write("a.json", values_doc({ flag1: "b" }))
            5.times { reloader.trigger }

            expect(wait_for { recorder.applied.length == 2 }).to be true
            sleep 0.4
            expect(recorder.applied.length).to eq(2)
            expect(recorder.flag_values).to eq({ flag1: "b" })
          end
        end

        it "restarts the debounce window when a trigger arrives during it" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], debounce_delay: 0.2) do |reloader, recorder|
            reloader.reload_now
            write("a.json", values_doc({ flag1: "b" }))
            reloader.trigger
            sleep 0.12
            reloader.trigger
            sleep 0.12

            expect(recorder.applied.length).to eq(1)
            expect(wait_for { recorder.applied.length == 2 }).to be true
          end
        end

        it "reloads at once for each trigger when the debounce delay is zero" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], debounce_delay: 0) do |reloader, recorder|
            reloader.reload_now
            write("a.json", values_doc({ flag1: "b" }))
            reloader.trigger
            expect(wait_for(0.5) { recorder.applied.length == 2 }).to be true
            write("a.json", values_doc({ flag1: "c" }))
            reloader.trigger
            expect(wait_for(0.5) { recorder.applied.length == 3 }).to be true
            expect(recorder.flag_values).to eq({ flag1: "c" })
          end
        end

        it "applies a triggered reload even when the content is unchanged unless told to skip" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], debounce_delay: 0) do |reloader, recorder|
            reloader.reload_now
            reloader.trigger

            expect(wait_for { recorder.applied.length == 2 }).to be true
          end
        end

        it "skips a reload whose content is identical to the last applied content" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], debounce_delay: 0, skip_unchanged: true) do |reloader, recorder|
            reloader.reload_now
            reloader.trigger
            sleep 0.3
            expect(recorder.applied.length).to eq(1)

            write("a.json", values_doc({ flag1: "b" }))
            reloader.trigger
            expect(wait_for { recorder.applied.length == 2 }).to be true
          end
        end

        it "applies a success that follows a failure even when the content is unchanged" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], retry_delay: 0, skip_unchanged: true) do |reloader, recorder|
            reloader.reload_now
            write("a.json", '{"flagValues"')
            reloader.reload_now
            write("a.json", values_doc({ flag1: "a" }))
            reloader.reload_now

            expect(recorder.applied.length).to eq(2)
            expect(recorder.errors.length).to eq(1)
          end
        end

        it "stamps the version returned by next_version on every entry of a reload" do
          a = write("a.json", { flagValues: { flag1: "a" }, flags: { flag2: { key: "flag2", version: 9, on: false, variations: [1] } } }.to_json)
          versions = [5, 6]

          with_reloader([a], debounce_delay: 0, next_version: -> { versions.shift }) do |reloader, recorder|
            reloader.reload_now
            expect(recorder.applied[0].flags[:flag1].version).to eq(5)
            expect(recorder.applied[0].flags[:flag2].version).to eq(5)

            reloader.trigger
            expect(wait_for { recorder.applied.length == 2 }).to be true
            expect(recorder.applied[1].flags[:flag1].version).to eq(6)
          end
        end

        it "runs reloads one at a time even when triggers overlap" do
          a = write("a.json", values_doc({ flag1: "a" }))
          active = Concurrent::AtomicFixnum.new(0)
          max_active = Concurrent::AtomicFixnum.new(0)
          applied = Concurrent::AtomicFixnum.new(0)
          apply = lambda do |_merged|
            current = active.increment
            max_active.update { |m| [m, current].max }
            sleep 0.1
            active.decrement
            applied.increment
          end
          reloader = Reloader.new(paths: [a], logger: $null_log, apply: apply, debounce_delay: 0)

          begin
            threads = Array.new(4) do
              Thread.new do
                reloader.reload_now
                reloader.trigger
              end
            end
            threads.each(&:join)

            expect(wait_for { applied.value >= 5 }).to be true
            expect(max_active.value).to eq(1)
          ensure
            reloader.stop
          end
        end

        it "does not apply after it is stopped" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], debounce_delay: 0) do |reloader, recorder|
            reloader.reload_now
            reloader.stop
            write("a.json", values_doc({ flag1: "b" }))
            reloader.trigger
            expect(reloader.reload_now).to be true
            sleep 0.2

            expect(recorder.applied.length).to eq(1)
          end
        end

        it "does not report a failure after it is stopped" do
          a = write("a.json", '{"flagValues"')

          with_reloader([a]) do |reloader, recorder|
            reloader.stop
            expect(reloader.reload_now).to be true

            expect(recorder.errors).to be_empty
          end
        end

        it "logs a change-triggered reload at info level" do
          a = write("a.json", values_doc({ flag1: "a" }))
          logger = CapturingLogger.new

          with_reloader([a], logger: logger, debounce_delay: 0) do |reloader, recorder|
            reloader.reload_now
            reloader.trigger
            expect(wait_for { recorder.applied.length == 2 }).to be true

            expect(logger.output).to include("Reloading flag data after detecting a change")
          end
        end
      end
    end
  end
end
