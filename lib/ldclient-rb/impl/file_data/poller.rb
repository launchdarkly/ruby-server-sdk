# frozen_string_literal: true

require "ldclient-rb/impl/repeating_task"

module LaunchDarkly
  module Impl
    module FileData
      #
      # Detects changes to a set of files by examining them on a fixed interval. Use it where file
      # system change notifications are not available or not reliable. A change to the
      # modification time or the size of any file invokes the callback. A file that appears or
      # disappears is also a change. A file that cannot be examined counts as absent.
      #
      # The poller samples the files once per interval and compares only modification time and
      # size. A rewrite that keeps both values is not detected.
      #
      # Detection is generous. The callback can run for a change that does not alter the
      # effective data. Feed it into a {Reloader}, whose debouncing and skip-unchanged handling
      # absorb the excess.
      #
      # @private
      #
      class Poller
        # The observed state of one file, or its absence.
        FileState = Struct.new(:exists, :mtime, :size)

        ABSENT = FileState.new(false, nil, nil).freeze
        private_constant :ABSENT

        #
        # Creates and starts a poller. It examines the files once before it returns, so only later
        # changes invoke the callback. Call {#stop} to stop it.
        #
        # @param paths [Array<String>] absolute paths of the files to examine
        # @param interval [Numeric] seconds between examinations
        # @param on_change [#call] invoked with no arguments when a change is detected
        # @param logger [Logger]
        #
        def initialize(paths, interval, on_change, logger)
          @paths = paths
          @on_change = on_change
          @last = Poller.observe_all(paths)
          @task = RepeatingTask.new(interval, interval, method(:examine), logger, "LD/FileDataPoller")
          @task.start
        end

        #
        # Stops the poller and waits for the worker thread to finish. A callback that is already
        # running completes first.
        #
        def stop
          @task.stop
        end

        #
        # Examines every file and returns the observed states, in path order.
        #
        # @param paths [Array<String>]
        # @return [Array<FileState>]
        #
        def self.observe_all(paths)
          paths.map do |path|
            begin
              stat = File.stat(path)
              FileState.new(true, stat.mtime, stat.size)
            rescue SystemCallError
              ABSENT
            end
          end
        end

        private def examine
          current = Poller.observe_all(@paths)
          changed = current != @last
          @last = current
          @on_change.call if changed
        end
      end
    end
  end
end
