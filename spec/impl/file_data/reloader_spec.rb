# frozen_string_literal: true

require "spec_helper"
require "capturing_logger"
require "in_place_writes"
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

        # Applications rewrite data files in place, which is not atomic. The tests do too, deliberately
        # slowly: a file that exists is truncated, and written 30 ms later, so a load can find it
        # empty, as it would with an application's writes, instead of only by chance.
        def write(name, content)
          if File.exist?(path(name))
            InPlaceWrites.rewrite(path(name), content, 0.03)
          else
            File.write(path(name), content)
          end
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

        # Collects apply and on_error calls in a thread-safe way. It raises from the first `reject`
        # apply calls, as a consumer that cannot use a result does.
        class Recorder
          attr_reader :applied, :errors

          def initialize(reject: 0)
            @lock = Mutex.new
            @applied = []
            @errors = []
            @reject = reject
          end

          def apply(merged)
            @lock.synchronize do
              if @reject > 0
                @reject -= 1
                raise ArgumentError, "the result was rejected"
              end
              @applied << merged
            end
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

        def with_reloader(paths, logger: $null_log, reject: 0, **options)
          recorder = Recorder.new(reject: reject)
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

            # The retry recovers with the fixed content. The write is in place, so a retry can
            # find the file empty while it is being written. It reads the file again later
            # instead of applying it.
            expect(wait_for { recorder.applied.length >= 1 }).to be true
            expect(recorder.applied.map { |merged| merged.flags.keys }).to all(eq([:flag1]))
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

        it "reports an exception from apply as a failed reload and applies the same content on the retry" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], reject: 1, retry_delay: 0.1) do |reloader, recorder|
            expect(reloader.reload_now).to be false
            expect(recorder.applied).to be_empty
            expect(recorder.errors.length).to eq(1)
            expect(recorder.errors[0]).to be_a(ArgumentError)

            # The retry applies the content that was rejected, so a consumer that recovers sees it.
            expect(wait_for { recorder.applied.length == 1 }).to be true
            expect(recorder.flag_values).to eq({ flag1: "a" })
          end
        end

        it "does not skip content as unchanged after apply rejected it" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], reject: 1, retry_delay: 0, skip_unchanged: true) do |reloader, recorder|
            expect(reloader.reload_now).to be false

            # The same content again. It was never applied, so it is not skipped as unchanged.
            expect(reloader.reload_now).to be true
            expect(recorder.flag_values).to eq({ flag1: "a" })
          end
        end

        it "reloads on a later trigger after apply raised during a triggered reload" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], reject: 1, debounce_delay: 0, retry_delay: 0) do |reloader, recorder|
            reloader.trigger
            expect(wait_for { recorder.errors.length == 1 }).to be true

            write("a.json", values_doc({ flag1: "b" }))
            reloader.trigger
            expect(wait_for { recorder.applied.length == 1 }).to be true
            expect(recorder.flag_values).to eq({ flag1: "b" })
          end
        end

        it "reports a repeated rejection by apply once" do
          a = write("a.json", values_doc({ flag1: "a" }))

          with_reloader([a], reject: 2, retry_delay: 0) do |reloader, recorder|
            expect(reloader.reload_now).to be false
            expect(reloader.reload_now).to be false

            # The second rejection repeats the first, so on_error is not invoked again.
            expect(recorder.errors.length).to eq(1)
            expect(reloader.reload_now).to be true
            expect(recorder.applied.length).to eq(1)
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

        it "writes the configured prefix once on the log line for an unexpected error" do
          a = write("a.json", values_doc({ flag1: "a" }))
          logger = CapturingLogger.new
          allow(FileData).to receive(:read_file).and_raise(RuntimeError, "unexpected")

          with_reloader([a], logger: logger, debounce_delay: 0, log_prefix: "[LDClient] Prefix:") do |reloader, _recorder|
            reloader.trigger

            expect(wait_for { logger.output.include?("Unexpected error") }).to be true
            expect(logger.output).to match(/ERROR -- : \[LDClient\] Prefix: Unexpected error in file data reloader/)
          end
        end

        describe "a file that is found empty" do
          # The retry comes long enough after the change signal for a test to finish writing the
          # file before it, even on a slow machine.
          let(:retry_delay) { 1.5 }

          # Shorter than the retry delay, so a load that happens within it after a change signal
          # is not the retry.
          let(:before_the_retry) { 1.0 }

          let(:logger) { CapturingLogger.new }

          let(:read_again_log) { "reading it again before applying it" }

          def yaml_doc(values)
            "flagValues:\n" + values.map { |key, value| "  #{key}: #{value}\n" }.join
          end

          def read_again_logged?
            logger.output.include?(read_again_log)
          end

          def hold_count
            logger.output.scan(read_again_log).length
          end

          def with_empty_file_reloader(paths, **options, &block)
            with_reloader(paths, logger: logger, debounce_delay: 0.01, retry_delay: retry_delay, **options, &block)
          end

          it "is held back before it is applied" do
            # A writer that rewrites the file in place truncates it and then writes the new content.
            # In YAML an empty file is valid, so applying it would briefly remove every entry.
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              reloader.trigger
              expect(wait_for { read_again_logged? }).to be true
              expect(logger.output).to include("DEBUG -- : [LDClient] File #{y} is empty, possibly while it is being rewritten")

              # The retry reads the rewritten file.
              File.write(y, yaml_doc(flag2: true))
              expect(wait_for(retry_delay + 2) { recorder.applied.length == 2 }).to be true
              expect(recorder.flag_values).to eq({ flag2: true })
              expect(recorder.errors).to be_empty
              expect(logger.output).not_to include("ERROR")
            end
          end

          it "counts a file with only white space as empty" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, " \n\r\n  \n")
              reloader.trigger

              expect(wait_for { read_again_logged? }).to be true
              expect(recorder.applied.length).to eq(1)
            end
          end

          it "is applied by the retry when a YAML file stays empty" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              reloader.trigger
              expect(wait_for { read_again_logged? }).to be true
              expect(wait_for(before_the_retry) { recorder.applied.length > 1 }).to be false

              # The file is still empty when the retry reads it, so it is a document with no entries.
              expect(wait_for(retry_delay + 2) { recorder.applied.length == 2 }).to be true
              expect(recorder.applied[-1].empty?).to be true
              expect(recorder.errors).to be_empty
            end
          end

          it "is not held back again once its empty state is applied" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              reloader.trigger
              expect(wait_for(retry_delay + 2) { recorder.applied.length == 2 }).to be true

              # The applied data has no content from the file, so a new truncation is applied at once.
              File.write(y, "")
              reloader.trigger
              expect(wait_for(before_the_retry) { recorder.applied.length == 3 }).to be true
              expect(recorder.applied[-1].empty?).to be true
              expect(logger.output.scan(read_again_log).length).to eq(1)
            end
          end

          it "is not reported by the load that finds an emptied JSON file, and the retry reports it" do
            a = write("a.json", values_doc({ flag1: "a" }))

            with_empty_file_reloader([a]) do |reloader, recorder|
              reloader.reload_now
              File.write(a, "")
              reloader.trigger
              expect(wait_for { read_again_logged? }).to be true
              expect(recorder.errors).to be_empty

              # The retry finds the file still empty, which is not a JSON document. The data stays.
              expect(wait_for(retry_delay + 2) { recorder.errors.length == 1 }).to be true
              expect(recorder.errors[0]).to be_a(ReadError)
              expect(recorder.errors[0].message).to include("the file has no content, which is not a JSON document")
              expect(recorder.applied.length).to eq(1)
            end
          end

          it "is not applied by a further change signal within the retry delay" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              reloader.trigger
              expect(wait_for { read_again_logged? }).to be true

              # The file has not been written since, so the delay goes on from the first load that
              # found it empty, and a stream of change signals cannot hold it back longer.
              reloader.trigger
              expect(wait_for { logger.output.scan(read_again_log).length == 2 }).to be true
              expect(recorder.applied.length).to eq(1)
              expect(wait_for(retry_delay + 2) { recorder.applied.length == 2 }).to be true
              expect(recorder.applied[-1].empty?).to be true
            end
          end

          it "is held back again when a second rewrite truncates it before a load reads its content" do
            # Two quick in-place rewrites: the write of the first and the truncation of the second
            # come before the next load, which finds the file empty again. It is a new rewrite, so
            # the delay starts again.
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              reloader.trigger
              expect(wait_for { read_again_logged? }).to be true

              sleep 0.02
              File.write(y, yaml_doc(flag2: true))
              File.write(y, "")
              reloader.trigger
              expect(wait_for { logger.output.scan(read_again_log).length == 2 }).to be true

              File.write(y, yaml_doc(flag3: true))
              reloader.trigger
              expect(wait_for(before_the_retry) { recorder.applied.length == 2 }).to be true
              expect(recorder.flag_values).to eq({ flag3: true })
            end
          end

          it "is held back again when the retry finds a second truncation" do
            # A retry, or the next poll, can find the file empty again after a second rewrite started.
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              reloader.trigger
              expect(wait_for { read_again_logged? }).to be true

              # No change signal from here on: only the retries read the file.
              sleep 0.02
              File.write(y, yaml_doc(flag2: true))
              File.write(y, "")
              expect(wait_for(retry_delay + 2) { logger.output.scan(read_again_log).length == 2 }).to be true
              expect(recorder.applied.length).to eq(1)

              File.write(y, yaml_doc(flag3: true))
              expect(wait_for(retry_delay + 2) { recorder.applied.length == 2 }).to be true
              expect(recorder.flag_values).to eq({ flag3: true })
            end
          end

          it "is held back again when a change to another file starts a load within the delay" do
            a = write("a.yaml", yaml_doc(flag1: true))
            b = write("b.yaml", yaml_doc(flag2: true))

            with_empty_file_reloader([a, b]) do |reloader, recorder|
              reloader.reload_now
              File.write(a, "")
              reloader.trigger
              expect(wait_for { read_again_logged? }).to be true

              # The load for the change to b finds a still empty, within the delay.
              File.write(b, yaml_doc(flag2: false))
              reloader.trigger
              expect(wait_for { logger.output.scan(read_again_log).length == 2 }).to be true
              expect(recorder.applied.length).to eq(1)

              File.write(a, yaml_doc(flag1: false))
              reloader.trigger
              expect(wait_for(before_the_retry) { recorder.applied.length == 2 }).to be true
              expect(recorder.flag_values).to eq({ flag1: false, flag2: false })
            end
          end

          it "is held back when the data that was kept as unchanged has content from it" do
            # The same content moves from one file to another, so the reload is skipped as unchanged,
            # but the data in effect now comes from the second file.
            a = write("a.yaml", yaml_doc(flag1: true))
            b = path("b.yaml")

            with_empty_file_reloader([a, b], skip_missing_paths: true, skip_unchanged: true) do |reloader, recorder|
              expect(reloader.reload_now).to be true
              File.write(b, yaml_doc(flag1: true))
              File.delete(a)
              expect(reloader.reload_now).to be true
              expect(recorder.applied.length).to eq(1)

              File.write(b, "")
              expect(reloader.reload_now).to be false
              expect(recorder.applied.length).to eq(1)
            end
          end

          it "does not keep a load from failing on another file that cannot be parsed" do
            a = write("a.yaml", yaml_doc(flag1: true))
            b = write("b.json", values_doc({ flag2: "b" }))

            with_empty_file_reloader([a, b]) do |reloader, recorder|
              reloader.reload_now
              File.write(a, "")
              File.write(b, '{"flagValues"')
              reloader.trigger

              # The load that puts a off reports b's failure, before the retry.
              expect(wait_for(before_the_retry) { recorder.errors.length == 1 }).to be true
              expect(recorder.errors[0].path).to eq(b)
              expect(recorder.applied.length).to eq(1)
            end
          end

          it "does not delay the other files' changes when it is an empty placeholder from the start" do
            # An empty YAML file next to the data, such as a placeholder for later entries, has never
            # had content, so it is never read again.
            a = write("a.json", values_doc({ flag1: "a" }))
            placeholder = write("placeholder.yaml", "")

            with_empty_file_reloader([a, placeholder]) do |reloader, recorder|
              reloader.reload_now
              expect(recorder.flag_values).to eq({ flag1: "a" })

              File.write(a, values_doc({ flag1: "b" }))
              reloader.trigger
              expect(wait_for(before_the_retry) { recorder.applied.length == 2 }).to be true
              expect(recorder.flag_values).to eq({ flag1: "b" })
              expect(read_again_logged?).to be false
            end
          end

          it "is applied at once when it was missing at its last read" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y], skip_missing_paths: true) do |reloader, recorder|
              reloader.reload_now
              File.delete(y)
              reloader.trigger
              expect(wait_for { recorder.applied.length == 2 }).to be true
              expect(recorder.applied[-1].empty?).to be true

              # A missing file has no content, so the empty file that replaces it is not read again.
              File.write(y, "")
              reloader.trigger
              expect(wait_for(before_the_retry) { recorder.applied.length == 3 }).to be true
              expect(recorder.applied[-1].empty?).to be true
              expect(read_again_logged?).to be false
            end
          end

          it "is held back by a retry left over from an earlier failure instead of applied empty" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "flagValues: [")
              reloader.trigger
              expect(wait_for { recorder.errors.length == 1 }).to be true

              # No change signal from here on: only the retries read the file.
              File.write(y, "")
              expect(wait_for(retry_delay + 2) { read_again_logged? }).to be true
              File.write(y, yaml_doc(flag2: true))
              expect(wait_for(retry_delay + 2) { recorder.applied.length == 2 }).to be true
              expect(recorder.flag_values).to eq({ flag2: true })
            end
          end

          it "makes reload_now return false and arms the retry" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              expect(reloader.reload_now).to be true
              File.write(y, "")

              expect(reloader.reload_now).to be false
              expect(read_again_logged?).to be true
              expect(recorder.errors).to be_empty

              # The retry applies the file, which is still empty.
              expect(wait_for(retry_delay + 2) { recorder.applied.length == 2 }).to be true
              expect(recorder.applied[-1].empty?).to be true
            end
          end

          it "neither logs nor arms a retry when the reloader is stopped while the files are read" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_empty_file_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              allow(FileData).to receive(:read_file).and_wrap_original do |_original, _path|
                reloader.stop
                ""
              end

              expect(reloader.reload_now).to be true
              expect(read_again_logged?).to be false
              expect(recorder.applied.length).to eq(1)
            end
          end

          it "is applied at once when there are no automatic retries" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_reloader([y], logger: logger, retry_delay: 0) do |reloader, recorder|
              reloader.reload_now

              # Without a retry nothing would read the file again, so the load applies it as it is.
              File.write(y, "")
              expect(reloader.reload_now).to be true
              expect(recorder.applied[-1].empty?).to be true
              expect(read_again_logged?).to be false
            end
          end

          it "is a document with no entries at the initial load when it is YAML" do
            y = write("a.yaml", "")

            with_empty_file_reloader([y]) do |reloader, recorder|
              expect(reloader.reload_now).to be true
              expect(recorder.applied[0].empty?).to be true
            end
          end

          it "fails to parse at the initial load when it is JSON" do
            a = write("a.json", "")

            with_empty_file_reloader([a]) do |reloader, recorder|
              expect(reloader.reload_now).to be false
              expect(recorder.applied).to be_empty
              expect(recorder.errors[0].message).to include("the file has no content, which is not a JSON document")
            end
          end

          it "arms the retry of a hold for the rest of the delay, plus a tenth of it" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_reloader([y], logger: logger, debounce_delay: 0.01, retry_delay: 2.0) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              reloader.trigger
              expect(wait_for { hold_count == 1 }).to be true
              first_hold = Time.now

              # A load halfway through the delay holds the file back again, and arms the retry for
              # the rest of the delay, not for a whole delay.
              sleep 1.0
              reloader.trigger
              expect(wait_for { hold_count == 2 }).to be true
              expect(wait_for(4) { recorder.applied.length == 2 }).to be true
              expect(Time.now - first_hold).to be_between(1.9, 2.7)
            end
          end
        end

        describe "holding back a file, on a controlled clock" do
          # A monotonic clock that only moves when a test moves it.
          class FakeClock
            attr_reader :now

            def initialize
              @now = 1000.0
            end

            def advance(seconds)
              @now += seconds
            end
          end

          # A retry delay of an hour on the controlled clock, so that no real retry fires during a
          # test. Each load is a synchronous reload_now.
          let(:hour) { 3600.0 }
          let(:clock) { FakeClock.new }
          let(:logger) { CapturingLogger.new }

          def yaml_doc(values)
            "flagValues:\n" + values.map { |key, value| "  #{key}: #{value}\n" }.join
          end

          def hold_count
            logger.output.scan("reading it again before applying it").length
          end

          # Lets the next write get a later modification time on a file system whose timestamps only
          # move once per clock tick of the kernel.
          def next_tick
            sleep 0.02
          end

          def with_clocked_reloader(paths, **options, &block)
            with_reloader(paths, logger: logger, retry_delay: hour, clock: clock.method(:now), **options, &block)
          end

          it "holds the file back until it has stayed empty for exactly the retry delay" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_clocked_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              expect(reloader.reload_now).to be false

              clock.advance(0.95 * hour)
              expect(reloader.reload_now).to be false
              expect(recorder.applied.length).to eq(1)

              clock.advance(0.05 * hour)
              expect(reloader.reload_now).to be true
              expect(recorder.applied[-1].empty?).to be true
            end
          end

          it "starts the delay over when the file is written while it is empty" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_clocked_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              expect(reloader.reload_now).to be false

              # Rewritten and truncated again between two loads.
              clock.advance(0.6 * hour)
              next_tick
              File.write(y, yaml_doc(flag2: true))
              File.write(y, "")
              expect(reloader.reload_now).to be false

              clock.advance(0.6 * hour)
              expect(reloader.reload_now).to be false

              clock.advance(0.4 * hour)
              expect(reloader.reload_now).to be true
              expect(recorder.applied[-1].empty?).to be true
            end
          end

          it "reads the state of the file a symbolic link leads to" do
            skip "symbolic links need extra privileges on Windows" if Gem.win_platform?
            target = write("target.yaml", yaml_doc(flag1: true))
            link = path("link.yaml")
            File.symlink(target, link)

            with_clocked_reloader([link]) do |reloader, recorder|
              reloader.reload_now
              File.write(target, "")
              expect(reloader.reload_now).to be false

              clock.advance(0.6 * hour)
              next_tick
              File.write(target, yaml_doc(flag2: true))
              File.write(target, "")
              expect(reloader.reload_now).to be false

              # The target was written, so its delay started again.
              clock.advance(0.6 * hour)
              expect(reloader.reload_now).to be false
              expect(recorder.applied.length).to eq(1)
            end
          end

          it "stops holding back after five retry delays while one file keeps being rewritten" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_clocked_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              expect(reloader.reload_now).to be false

              # Truncating the file again changes its modification time, so every load finds a new
              # rewrite.
              9.times do
                clock.advance(0.5 * hour)
                next_tick
                File.write(y, "")
                expect(reloader.reload_now).to be false
              end

              clock.advance(0.5 * hour)
              next_tick
              File.write(y, "")
              expect(reloader.reload_now).to be true
              expect(recorder.applied[-1].empty?).to be true
            end
          end

          it "stops holding back after five retry delays while two files are rewritten in turn" do
            a = write("a.yaml", yaml_doc(flag1: true))
            b = write("b.yaml", yaml_doc(flag2: true))

            with_clocked_reloader([a, b]) do |reloader, recorder|
              reloader.reload_now
              File.write(a, "")
              expect(reloader.reload_now).to be false

              # Each load finds one of the files in the middle of a rewrite and the other one whole.
              9.times do |i|
                clock.advance(0.5 * hour)
                next_tick
                emptied, rewritten = i.even? ? [b, a] : [a, b]
                File.write(rewritten, yaml_doc(rewritten == a ? { flag1: true } : { flag2: true }))
                File.write(emptied, "")
                expect(reloader.reload_now).to be false
              end
              expect(recorder.applied.length).to eq(1)

              clock.advance(0.5 * hour)
              File.write(b, yaml_doc(flag2: true))
              File.write(a, "")
              expect(reloader.reload_now).to be true
              expect(recorder.flag_values).to eq({ flag2: true })
            end
          end

          it "applies files that are emptied together after one retry delay" do
            a = write("a.yaml", yaml_doc(flag1: true))
            b = write("b.yaml", yaml_doc(flag2: true))

            with_clocked_reloader([a, b]) do |reloader, recorder|
              reloader.reload_now
              File.write(a, "")
              File.write(b, "")
              expect(reloader.reload_now).to be false
              expect(hold_count).to eq(2)

              clock.advance(hour)
              expect(reloader.reload_now).to be true
              expect(recorder.applied[-1].empty?).to be true
            end
          end

          it "holds back YAML that is only a comment or a document marker, and applies {} at once" do
            y = write("a.yaml", yaml_doc(flag1: true))

            with_clocked_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "# overrides for the incident\n")
              expect(reloader.reload_now).to be false
              File.write(y, "---\n")
              expect(reloader.reload_now).to be false
              expect(recorder.applied.length).to eq(1)

              File.write(y, "{}\n")
              expect(reloader.reload_now).to be true
              expect(recorder.applied[-1].empty?).to be true
            end
          end

          it "applies a JSON file that is {} at once" do
            a = write("a.json", values_doc({ flag1: "a" }))

            with_clocked_reloader([a]) do |reloader, recorder|
              reloader.reload_now
              File.write(a, "{}")
              expect(reloader.reload_now).to be true
              expect(recorder.applied[-1].empty?).to be true
              expect(hold_count).to eq(0)
            end
          end

          it "keeps parsing a JSON file that stays empty, without holding it back again" do
            a = write("a.json", values_doc({ flag1: "a" }))

            with_clocked_reloader([a]) do |reloader, recorder|
              reloader.reload_now
              File.write(a, "")
              expect(reloader.reload_now).to be false

              clock.advance(hour)
              expect(reloader.reload_now).to be false
              expect(recorder.errors.length).to eq(1)
              clock.advance(hour)
              expect(reloader.reload_now).to be false
              expect(hold_count).to eq(1)
              expect(recorder.applied.length).to eq(1)
            end
          end

          it "holds back a JSON file that stayed empty for long when it is rewritten" do
            # The failing loads ended the run of holding loads, so the rewrite is held back although
            # the file was first found empty more than five retry delays ago.
            a = write("a.json", values_doc({ flag1: "a" }))

            with_clocked_reloader([a]) do |reloader, recorder|
              reloader.reload_now
              File.write(a, "")
              expect(reloader.reload_now).to be false
              clock.advance(hour)
              expect(reloader.reload_now).to be false
              clock.advance(5 * hour)
              expect(reloader.reload_now).to be false
              expect(recorder.errors.length).to eq(1)

              next_tick
              File.write(a, "")
              expect(reloader.reload_now).to be false
              expect(hold_count).to eq(2)
              File.write(a, values_doc({ flag1: "b" }))
              expect(reloader.reload_now).to be true
              expect(recorder.flag_values).to eq({ flag1: "b" })
              expect(recorder.errors.length).to eq(1)
            end
          end

          it "holds back a file emptied again after its content was read, even if its state looks the same" do
            # On a file system with coarse modification times, a rewrite can leave the state of an
            # empty file unchanged.
            y = write("a.yaml", yaml_doc(flag1: true))
            allow(Poller).to receive(:observe).and_return(Poller::FileState.new(true, Time.at(0), 0))

            with_clocked_reloader([y]) do |reloader, _recorder|
              reloader.reload_now
              File.write(y, "")
              expect(reloader.reload_now).to be false
              File.write(y, yaml_doc(flag2: true))
              expect(reloader.reload_now).to be true

              clock.advance(2 * hour)
              File.write(y, "")
              expect(reloader.reload_now).to be false
            end
          end

          it "holds back a file created empty after it was missing, even if its state looks the same" do
            y = write("a.yaml", yaml_doc(flag1: true))
            allow(Poller).to receive(:observe).and_return(Poller::FileState.new(true, Time.at(0), 0))

            with_clocked_reloader([y]) do |reloader, recorder|
              reloader.reload_now
              File.write(y, "")
              expect(reloader.reload_now).to be false

              # Without skipping missing paths, a missing file fails the load and the data stays.
              File.delete(y)
              expect(reloader.reload_now).to be false
              expect(recorder.errors.length).to eq(1)

              clock.advance(2 * hour)
              File.write(y, "")
              expect(reloader.reload_now).to be false
              expect(recorder.applied.length).to eq(1)
            end
          end

          it "does not hold back a placeholder or a file that was missing" do
            a = write("a.yaml", yaml_doc(flag1: true))
            placeholder = write("placeholder.yaml", "")
            later = path("later.yaml")

            with_clocked_reloader([a, placeholder, later], skip_missing_paths: true) do |reloader, recorder|
              reloader.reload_now
              File.write(later, "")
              expect(reloader.reload_now).to be true
              expect(recorder.flag_values).to eq({ flag1: true })
              expect(hold_count).to eq(0)
            end
          end
        end
      end
    end
  end
end
