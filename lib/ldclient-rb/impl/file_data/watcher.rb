# frozen_string_literal: true

require "ldclient-rb/impl/repeating_task"
require "ldclient-rb/impl/util"

require "concurrent/atomics"
require "set"

module LaunchDarkly
  module Impl
    module FileData
      #
      # Detects changes to a set of files through file system change notifications. The
      # notification mechanism comes from the optional `listen` gem, which the SDK does not depend
      # on. Check {Watcher.available?} before constructing a watcher.
      #
      # On Linux the watcher uses `rb-inotify`, which `listen` depends on, to watch the directory of
      # each file without descending into subdirectories. Elsewhere it uses `listen` itself, which
      # scans the whole directory tree under each watched directory.
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

        INOTIFY_EVENTS = [:create, :modify, :close_write, :attrib, :delete, :moved_to, :moved_from].freeze
        private_constant :INOTIFY_EVENTS

        #
        # Returns true if a change notification mechanism can be loaded.
        #
        # @return [Boolean]
        #
        def self.available?
          inotify_available? || listen_available?
        end

        #
        # Returns true if `rb-inotify` can be loaded. It is a dependency of `listen` on Linux and
        # does not load on other platforms.
        #
        # @return [Boolean]
        #
        def self.inotify_available?
          @inotify_available = load_library("rb-inotify") if @inotify_available.nil?
          @inotify_available
        end

        #
        # Returns true if the `listen` gem can be loaded.
        #
        # @return [Boolean]
        #
        def self.listen_available?
          @listen_available = load_library("listen") if @listen_available.nil?
          @listen_available
        end

        private_class_method def self.load_library(name)
          require name
          true
        rescue LoadError, StandardError
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

          listener = Watcher.inotify_available? ? start_inotify : start_listen

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

        #
        # Watches the real directory of each file, without descending into subdirectories, and
        # reports events whose file name is one of the watched names in that directory.
        #
        private def start_inotify
          names_by_directory = {}
          @paths.each do |p|
            real_directory = File.realpath(File.dirname(p))
            (names_by_directory[real_directory] ||= Set.new) << File.basename(p)
          end

          notifier = INotify::Notifier.new
          begin
            names_by_directory.each do |directory, names|
              notifier.watch(directory, *INOTIFY_EVENTS) do |event|
                @on_change.call if names.include?(event.name) && !@stopped.value
              end
            end
          rescue
            notifier.close
            raise
          end
          InotifyListener.new(notifier, @logger)
        end

        #
        # Watches the real directory of each file with the `listen` gem, which reports paths under
        # the real directory, so the paths to match are built the same way.
        #
        private def start_listen
          directories = @paths.map { |p| File.dirname(p) }.uniq
          real_directories = directories.map { |d| File.realpath(d) }
          watched = Set.new(@paths.map { |p| File.join(File.realpath(File.dirname(p)), File.basename(p)) })

          listener = Listen.to(*real_directories) do |modified, added, removed|
            changed = (modified + added + removed).any? { |p| watched.include?(p) }
            @on_change.call if changed && !@stopped.value
          end
          listener.start
          listener
        end

        private def log_setup_failure(message)
          if message == @last_error_message
            @logger.debug { "[LDClient] Unable to watch data files: #{message}" }
          else
            @last_error_message = message
            @logger.error { "[LDClient] Unable to watch data files: #{message}" }
          end
        end

        #
        # Runs an inotify notifier on its own thread and stops it on request.
        #
        class InotifyListener
          def initialize(notifier, logger)
            @notifier = notifier
            @thread = Thread.new do
              begin
                notifier.run
              rescue IOError, SystemCallError
                # The notifier was closed by stop.
              rescue => e
                Util.log_exception(logger, "Unexpected error in file data watcher", e)
              end
            end
            @thread.name = "LD/FileDataWatcher"
          end

          #
          # Stops the notifier and waits briefly for its thread. Closing the notifier ends the
          # blocking read that the thread is in.
          #
          def stop
            @notifier.stop
            @notifier.close
            @thread.join(2)
          end
        end
        private_constant :InotifyListener
      end
    end
  end
end
