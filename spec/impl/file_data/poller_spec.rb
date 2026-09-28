# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "ldclient-rb/impl/file_data"

module LaunchDarkly
  module Impl
    module FileData
      describe Poller do
        let(:interval) { 0.05 }

        around do |example|
          Dir.mktmpdir do |dir|
            @dir = dir
            example.run
          end
        end

        def path(name)
          File.join(@dir, name)
        end

        def wait_for(timeout = 3)
          deadline = Time.now + timeout
          until yield
            return false if Time.now > deadline
            sleep 0.01
          end
          true
        end

        def with_poller(paths)
          calls = Concurrent::AtomicFixnum.new(0)
          poller = Poller.new(paths, interval, -> { calls.increment }, $null_log)
          begin
            yield poller, calls
          ensure
            poller.stop
          end
        end

        it "invokes the callback when a file's modification time changes" do
          File.write(path("a.json"), "{}")
          with_poller([path("a.json")]) do |_poller, calls|
            File.utime(Time.now + 10, Time.now + 10, path("a.json"))
            expect(wait_for { calls.value >= 1 }).to be true
          end
        end

        it "invokes the callback when a file's size changes but its modification time does not" do
          File.write(path("a.json"), "{}")
          mtime = File.mtime(path("a.json"))
          with_poller([path("a.json")]) do |_poller, calls|
            File.write(path("a.json"), '{"flagValues": {}}')
            File.utime(mtime, mtime, path("a.json"))
            expect(wait_for { calls.value >= 1 }).to be true
          end
        end

        it "invokes the callback when a file appears" do
          with_poller([path("missing.json")]) do |_poller, calls|
            sleep interval * 2
            expect(calls.value).to eq(0)
            File.write(path("missing.json"), "{}")
            expect(wait_for { calls.value >= 1 }).to be true
          end
        end

        it "invokes the callback when a file disappears" do
          File.write(path("a.json"), "{}")
          with_poller([path("a.json")]) do |_poller, calls|
            File.delete(path("a.json"))
            expect(wait_for { calls.value >= 1 }).to be true
          end
        end

        it "watches every configured file" do
          File.write(path("a.json"), "{}")
          File.write(path("b.json"), "{}")
          with_poller([path("a.json"), path("b.json")]) do |_poller, calls|
            File.utime(Time.now + 10, Time.now + 10, path("b.json"))
            expect(wait_for { calls.value >= 1 }).to be true
          end
        end

        it "does not invoke the callback when nothing changed" do
          File.write(path("a.json"), "{}")
          with_poller([path("a.json")]) do |_poller, calls|
            sleep interval * 6
            expect(calls.value).to eq(0)
          end
        end

        it "does not invoke the callback after it is stopped" do
          File.write(path("a.json"), "{}")
          with_poller([path("a.json")]) do |poller, calls|
            poller.stop
            File.utime(Time.now + 10, Time.now + 10, path("a.json"))
            sleep interval * 6
            expect(calls.value).to eq(0)
          end
        end
      end
    end
  end
end
