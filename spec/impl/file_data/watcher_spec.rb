# frozen_string_literal: true

require "spec_helper"
require "capturing_logger"
require "fileutils"
require "tmpdir"
require "ldclient-rb/impl/file_data"

module LaunchDarkly
  module Impl
    module FileData
      describe Watcher do
        before do
          skip "the listen gem is not installed" unless Watcher.available?
        end

        around do |example|
          Dir.mktmpdir do |dir|
            @dir = dir
            example.run
          end
        end

        def path(name)
          File.join(@dir, name)
        end

        def wait_for(timeout = 5)
          deadline = Time.now + timeout
          until yield
            return false if Time.now > deadline
            sleep 0.02
          end
          true
        end

        def with_watcher(paths, logger: $null_log)
          calls = Concurrent::AtomicFixnum.new(0)
          watcher = Watcher.new(paths, -> { calls.increment }, logger)
          begin
            yield watcher, calls
          ensure
            watcher.stop
          end
        end

        # Returns the call count once it has stopped changing for a moment. One edit can produce a
        # burst of notifications, and a count taken in the middle of the burst would make the rest
        # of it look like a later signal.
        def settled(calls)
          count = calls.value
          loop do
            sleep 0.2
            break if calls.value == count
            count = calls.value
          end
          count
        end

        it "reports that the listen gem is available" do
          expect(Watcher.available?).to be true
        end

        it "invokes the callback when a watched file is modified" do
          File.write(path("a.json"), "{}")
          with_watcher([path("a.json")]) do |_watcher, calls|
            sleep 0.3
            File.write(path("a.json"), '{"flagValues": {}}')
            expect(wait_for { calls.value >= 1 }).to be true
          end
        end

        it "invokes the callback when a watched file that did not exist appears" do
          with_watcher([path("later.json")]) do |_watcher, calls|
            sleep 0.3
            File.write(path("later.json"), "{}")
            expect(wait_for { calls.value >= 1 }).to be true
          end
        end

        it "invokes the callback when a watched file is deleted" do
          File.write(path("a.json"), "{}")
          with_watcher([path("a.json")]) do |_watcher, calls|
            sleep 0.3
            File.delete(path("a.json"))
            expect(wait_for { calls.value >= 1 }).to be true
          end
        end

        it "ignores other files in the same directory" do
          File.write(path("a.json"), "{}")
          with_watcher([path("a.json")]) do |_watcher, calls|
            sleep 0.3
            File.write(path("other.json"), "{}")
            sleep 0.5
            expect(calls.value).to eq(0)
          end
        end

        it "watches files in more than one directory" do
          Dir.mkdir(path("sub"))
          File.write(path("a.json"), "{}")
          File.write(path("sub/b.json"), "{}")
          with_watcher([path("a.json"), path("sub/b.json")]) do |_watcher, calls|
            sleep 0.3
            File.write(path("sub/b.json"), '{"flagValues": {}}')
            expect(wait_for { calls.value >= 1 }).to be true
          end
        end

        it "logs when a directory does not exist and starts watching once it appears" do
          logger = CapturingLogger.new
          missing_dir = path("not-yet")
          with_watcher([File.join(missing_dir, "a.json")], logger: logger) do |_watcher, calls|
            expect(logger.output).to include("Unable to watch data files")
            expect(logger.output).to include("directory does not exist")
            sleep 0.2
            expect(calls.value).to eq(0)

            Dir.mkdir(missing_dir)
            # The watches are set up on the next retry, and the callback runs once at that point.
            expect(wait_for { calls.value >= 1 }).to be true
            before = calls.value

            sleep 0.3
            File.write(File.join(missing_dir, "a.json"), "{}")
            expect(wait_for { calls.value > before }).to be true
          end
        end

        it "logs when a watched directory is deleted and watches it again once it exists again" do
          skip "rb-inotify is not available on this platform" unless Watcher.inotify_available?

          logger = CapturingLogger.new
          Dir.mkdir(path("sub"))
          File.write(path("sub/a.json"), "{}")
          with_watcher([path("sub/a.json")], logger: logger) do |_watcher, calls|
            sleep 0.3
            FileUtils.rm_rf(path("sub"))
            expect(wait_for { logger.output.include?("WARN") }).to be true
            expect(logger.output).to match(/WARN.*#{Regexp.escape(path('sub'))}/)
            before = calls.value

            Dir.mkdir(path("sub"))
            File.write(path("sub/a.json"), "{}")
            # The watches are set up on the next retry, and the callback runs once at that point.
            expect(wait_for { calls.value > before }).to be true
            before = calls.value

            sleep 0.3
            File.write(path("sub/a.json"), '{"flagValues": {}}')
            expect(wait_for { calls.value > before }).to be true
          end
        end

        it "keeps retrying when a directory is lost again as soon as its watches are set up" do
          skip "rb-inotify is not available on this platform" unless Watcher.inotify_available?

          logger = CapturingLogger.new
          with_watcher([path("sub/a.json")], logger: logger) do |watcher, calls|
            # Take the directory away as soon as the watches are set up, and wait until the loss
            # has been handled, so that it is reported while the retry that set up the watches
            # is still finishing.
            lost_once = false
            allow(watcher).to receive(:try_start).and_wrap_original do |original|
              started = original.call
              if started && !lost_once
                lost_once = true
                FileUtils.rm_rf(path("sub"))
                # The loss has been handled once it is logged. The inotify thread cannot mark it,
                # as it used to: each directory has its own watch now, and the thread outlives one.
                wait_for { logger.output.include?("no longer exists") }
              end
              started
            end

            Dir.mkdir(path("sub"))
            expect(wait_for { calls.value >= 1 }).to be true

            # The retry that follows the second loss sets the watches up once the directory exists.
            Dir.mkdir(path("sub"))
            expect(wait_for { calls.value >= 2 }).to be true
          end
        end

        it "watches a directory that contains an unreadable subdirectory" do
          skip "the current user can read every directory" if Process.uid.zero?

          Dir.mkdir(path("private"))
          File.chmod(0o000, path("private"))
          begin
            File.write(path("a.json"), "{}")
            logger = CapturingLogger.new
            with_watcher([path("a.json")], logger: logger) do |_watcher, calls|
              expect(logger.output).not_to include("Unable to watch data files")
              sleep 0.3
              File.write(path("a.json"), '{"flagValues": {}}')
              expect(wait_for { calls.value >= 1 }).to be true
            end
          ensure
            File.chmod(0o755, path("private"))
          end
        end

        it "uses inotify on Linux and runs it on a named thread that stop ends" do
          skip "rb-inotify is not available on this platform" unless Watcher.inotify_available?

          File.write(path("a.json"), "{}")
          watcher = Watcher.new([path("a.json")], -> {}, $null_log)
          threads = Thread.list.select { |t| t.name == "LD/FileDataWatcher" }
          expect(threads.length).to eq 1

          watcher.stop

          expect(threads[0].alive?).to be false
        end

        it "does not invoke the callback after it is stopped" do
          File.write(path("a.json"), "{}")
          with_watcher([path("a.json")]) do |watcher, calls|
            sleep 0.3
            watcher.stop
            File.write(path("a.json"), '{"flagValues": {}}')
            sleep 0.5
            expect(calls.value).to eq(0)
          end
        end

        it "can be stopped while it is still retrying a missing directory" do
          with_watcher([path("not-yet/a.json")]) do |watcher, _calls|
            watcher.stop
            expect(Thread.list.map(&:name)).not_to include("LD/FileDataWatcherRetry")
          end
        end

        it "watches the directories that exist while another one is missing" do
          logger = CapturingLogger.new
          Dir.mkdir(path("sub"))
          File.write(path("sub/a.json"), "{}")
          missing_dir = path("not-yet")
          with_watcher([path("sub/a.json"), File.join(missing_dir, "b.json")], logger: logger) do |_watcher, calls|
            expect(logger.output).to include("directory does not exist: #{missing_dir}")
            sleep 0.3
            # The directory that exists is watched at once, not only when every directory exists.
            File.write(path("sub/a.json"), '{"flagValues": {}}')
            expect(wait_for { calls.value >= 1 }).to be true
            before = settled(calls)

            Dir.mkdir(missing_dir)
            # The watch is set up on the next retry, and the callback runs once at that point.
            expect(wait_for { calls.value > before }).to be true
            # Nothing is missing any more, so the retry ends and does not signal again.
            expect(wait_for { Thread.list.none? { |t| t.name == "LD/FileDataWatcherRetry" } }).to be true
            before = settled(calls)
            sleep 0.3
            expect(calls.value).to eq(before)

            File.write(File.join(missing_dir, "b.json"), "{}")
            expect(wait_for { calls.value > before }).to be true
          end
        end

        it "watches a lost directory again while another directory is still missing" do
          skip "rb-inotify is not available on this platform" unless Watcher.inotify_available?

          logger = CapturingLogger.new
          Dir.mkdir(path("sub"))
          File.write(path("sub/a.json"), "{}")
          with_watcher([path("sub/a.json"), path("not-yet/b.json")], logger: logger) do |_watcher, calls|
            FileUtils.rm_rf(path("sub"))
            expect(wait_for { logger.output.match?(/WARN.*#{Regexp.escape(path('sub'))}/) }).to be true
            before = settled(calls)

            Dir.mkdir(path("sub"))
            File.write(path("sub/a.json"), "{}")
            # The directory is watched again on the next retry, which signals once at that point,
            # although the other directory is still missing.
            expect(wait_for { calls.value > before }).to be true
            before = settled(calls)

            File.write(path("sub/a.json"), '{"flagValues": {}}')
            expect(wait_for { calls.value > before }).to be true
            expect(Dir.exist?(path("not-yet"))).to be false
            expect(logger.output).to include("directory does not exist: #{path('not-yet')}")
          end
        end

        it "stops while a directory is missing and runs no callback afterwards" do
          Dir.mkdir(path("sub"))
          File.write(path("sub/a.json"), "{}")
          with_watcher([path("sub/a.json"), path("not-yet/b.json")]) do |watcher, calls|
            sleep 0.3
            watcher.stop
            expect(Thread.list.map(&:name)).not_to include("LD/FileDataWatcherRetry")
            expect(Thread.list.map(&:name)).not_to include("LD/FileDataWatcher") if Watcher.inotify_available?

            Dir.mkdir(path("not-yet"))
            File.write(path("not-yet/b.json"), "{}")
            File.write(path("sub/a.json"), '{"flagValues": {}}')
            sleep 0.5
            expect(calls.value).to eq(0)
          end
        end
      end
    end
  end
end
