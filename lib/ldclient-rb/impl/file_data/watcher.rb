# frozen_string_literal: true

require "ldclient-rb/impl/repeating_task"

require "concurrent/atomics"
require "set"

module LaunchDarkly
  module Impl
    module FileData
      #
      # Detects changes to a set of files through file system change notifications, using the
      # optional `listen` gem. The gem is not a dependency of the SDK. Check {Watcher.available?}
      # before constructing a watcher.
      #
      # The watcher observes the directory of each file, so a configured file that does not exist
      # yet is picked up when it appears. If a directory does not exist, the watcher logs the
      # problem and retries once per second until it does. When the watches are in place after a
      # retry, the callback runs once, so that a change made while there was no watch is not missed.
      #
      # @private
      #
      class Watcher
        # Seconds between attempts to set up the watches after a failure.
        RETRY_INTERVAL = 1.0

        #
        # Returns true if the `listen` gem can be loaded.
        #
        # @return [Boolean]
        #
        def self.available?
          @available = load_listen if @available.nil?
          @available
        end

        private_class_method def self.load_listen
          require "listen"
          true
        rescue LoadError
          false
        end

        #
        # Creates and starts a watcher.
        #
        # @param paths [Array<String>] absolute paths of the files to watch
        # @param on_change [#call] invoked with no arguments when one of the files changes
        # @param logger [Logger]
        #
        def initialize(paths, on_change, logger)
          @paths = paths
          @on_change = on_change
          @logger = logger
          @stopped = Concurrent::AtomicBoolean.new(false)
          @lock = Mutex.new
          @listener = nil
          @retry_task = nil
          @last_error_message = nil

          return if try_start

          @retry_task = RepeatingTask.new(RETRY_INTERVAL, RETRY_INTERVAL, method(:retry_start), logger,
            "LD/FileDataWatcherRetry")
          @retry_task.start
        end

        #
        # Stops the watcher. No callback runs after this method returns, apart from one that is
        # already in progress.
        #
        def stop
          return unless @stopped.make_true

          @retry_task&.stop
          listener = @lock.synchronize do
            l = @listener
            @listener = nil
            l
          end
          listener&.stop
        end

        private def retry_start
          return if @stopped.value
          return unless try_start

          # This runs on the retry task's own thread, which RepeatingTask#stop allows.
          @retry_task.stop
          @on_change.call unless @stopped.value
        end

        #
        # Sets up the watches. Returns false, after logging, if that is not possible yet.
        #
        private def try_start
          directories = @paths.map { |p| File.dirname(p) }.uniq
          missing = directories.reject { |d| File.directory?(d) }
          unless missing.empty?
            log_setup_failure("directory does not exist: #{missing.join(', ')}")
            return false
          end

          # The listener reports paths under the real directory, so the paths to match are built
          # the same way.
          real_directories = directories.map { |d| File.realpath(d) }
          watched = Set.new(@paths.map { |p| File.join(File.realpath(File.dirname(p)), File.basename(p)) })

          listener = Listen.to(*real_directories) do |modified, added, removed|
            changed = (modified + added + removed).any? { |p| watched.include?(p) }
            @on_change.call if changed && !@stopped.value
          end
          listener.start

          @lock.synchronize do
            if @stopped.value
              listener.stop
            else
              @listener = listener
            end
          end
          @last_error_message = nil
          true
        rescue => e
          log_setup_failure(e.message)
          false
        end

        private def log_setup_failure(message)
          if message == @last_error_message
            @logger.debug { "[LDClient] Unable to watch data files: #{message}" }
          else
            @last_error_message = message
            @logger.error { "[LDClient] Unable to watch data files: #{message}" }
          end
        end
      end
    end
  end
end
