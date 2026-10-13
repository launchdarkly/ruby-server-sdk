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
      # yet is picked up when it appears. Each directory is watched on its own: one that does not
      # exist, or that is deleted while it is watched, is logged and retried once per second until
      # it exists, while the other directories stay watched. When a retry sets up a watch, the
      # callback runs once, so that a change made while there was no watch is not missed.
      #
      # @private
      #
      class Watcher
        # Seconds between attempts to set up the watches after a failure.
        RETRY_INTERVAL = 1.0

        INOTIFY_EVENTS = [:create, :modify, :close_write, :attrib, :delete, :moved_to, :moved_from,
                          :delete_self, :move_self].freeze
        private_constant :INOTIFY_EVENTS

        # The inotify event flags that mean the watched directory itself is gone.
        INOTIFY_DIRECTORY_LOST = [:delete_self, :move_self].freeze
        private_constant :INOTIFY_DIRECTORY_LOST

        # The watch on one real directory: the configured directories that resolve to it, the
        # names of the configured files in it, and a callable that removes the watch.
        WatchedDirectory = Struct.new(:directories, :names, :close)
        private_constant :WatchedDirectory

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
          @retry_task = nil
          @last_error_message = nil
          # The directories of the configured paths, in configuration order. A directory is in
          # @missing until it is watched, and then in @watched under its real path. The lock
          # guards both, @retry_task, and @inotify.
          @directories = paths.map { |p| File.dirname(p) }.uniq
          @missing = Set.new(@directories)
          @watched = {}
          @inotify = nil

          try_start
          schedule_retry unless @lock.synchronize { @missing.empty? }
        end

        #
        # Stops the watcher. No callback runs after this method returns, apart from one that is
        # already in progress.
        #
        def stop
          return unless @stopped.make_true

          closers, retry_task, inotify = @lock.synchronize do
            state = [@watched.values.map(&:close), @retry_task, @inotify]
            @watched.clear
            @retry_task = nil
            @inotify = nil
            state
          end
          retry_task&.stop
          closers.each(&:call)
          inotify&.stop
        end

        #
        # Starts the task that attempts to watch the missing directories once per second, unless
        # it already runs or the watcher is stopped.
        #
        private def schedule_retry
          @lock.synchronize do
            return if @stopped.value || !@retry_task.nil?

            @retry_task = RepeatingTask.new(RETRY_INTERVAL, RETRY_INTERVAL, method(:retry_start), @logger,
              "LD/FileDataWatcherRetry")
            @retry_task.start
          end
        end

        private def retry_start
          return if @stopped.value

          added = try_start
          # The task ends when nothing is missing. A directory lost meanwhile is back in @missing
          # before its loss report calls schedule_retry, so either the task is kept here or that
          # call starts a new one.
          retry_task = @lock.synchronize do
            next nil unless @missing.empty?

            task = @retry_task
            @retry_task = nil
            task
          end
          # This runs on the retry task's own thread, which RepeatingTask#stop allows.
          retry_task&.stop
          @on_change.call if added && !@stopped.value
        end

        #
        # Handles the loss of a watched directory. The notification mechanism reports it on its
        # own thread. The watch ends with the directory, so it is removed and set up again through
        # the same retry as at start, once the directory exists. The other directories keep their
        # watches.
        #
        private def directory_lost(real_directory)
          entry = @lock.synchronize do
            return if @stopped.value

            e = @watched.delete(real_directory)
            return if e.nil?

            @missing.merge(e.directories)
            e
          end
          @logger.warn { "[LDClient] Directory #{real_directory} no longer exists; its data files are watched again when it exists" }
          entry.close.call
          schedule_retry
        end

        #
        # Watches each missing directory that exists now. Returns true if at least one watch was
        # added. The directories that are still missing, and any watch that could not be set up,
        # are logged together, so that an unchanged situation repeats at debug level.
        #
        private def try_start
          added = false
          missing = []
          problems = []
          @lock.synchronize { @directories.select { |d| @missing.include?(d) } }.each do |directory|
            unless File.directory?(directory)
              missing << directory
              next
            end
            begin
              added = true if watch_directory(directory)
            rescue => e
              problems << e.message
            end
          end
          problems.unshift("directory does not exist: #{missing.join(', ')}") unless missing.empty?
          if problems.empty?
            @last_error_message = nil
          else
            log_setup_failure(problems.join("; "))
          end
          added
        end

        #
        # Watches the real directory of a configured directory, and records the names of the
        # configured files in it. Two configured directories can resolve to the same real
        # directory, which then has one watch for the names in both. Returns false if the watcher
        # is stopped.
        #
        private def watch_directory(directory)
          real_directory = File.realpath(directory)
          names = @paths.select { |p| File.dirname(p) == directory }.map { |p| File.basename(p) }
          @lock.synchronize do
            return false if @stopped.value

            entry = @watched[real_directory]
            if entry.nil?
              entry = WatchedDirectory.new(Set.new, Set.new, add_watch(real_directory))
              @watched[real_directory] = entry
            end
            entry.directories << directory
            entry.names.merge(names)
            @missing.delete(directory)
          end
          true
        end

        #
        # Adds the notification mechanism's watch on a real directory and returns a callable that
        # removes it. Called with the lock held, so that stop sees either no watch or a recorded
        # one.
        #
        private def add_watch(real_directory)
          Watcher.inotify_available? ? add_inotify_watch(real_directory) : start_listen(real_directory)
        end

        #
        # Adds a watch on the directory itself, without descending into subdirectories, to the one
        # inotify notifier, which is created with the first watch.
        #
        private def add_inotify_watch(real_directory)
          @inotify ||= InotifyListener.new(INotify::Notifier.new, @logger)
          watch = @inotify.watch(real_directory) { |event| inotify_event(real_directory, event) }
          lambda do
            begin
              watch.close
            rescue SystemCallError
              # The kernel already removed the watch along with the directory.
            end
          end
        end

        private def inotify_event(real_directory, event)
          return if @stopped.value

          if (event.flags & INOTIFY_DIRECTORY_LOST).empty?
            @on_change.call if watched_name?(real_directory, event.name)
          else
            directory_lost(real_directory)
          end
        end

        #
        # Watches a real directory with the `listen` gem, which reports paths under the real
        # directory, so a reported path is matched by its directory and name.
        #
        private def start_listen(real_directory)
          listener = Listen.to(real_directory) do |modified, added, removed|
            next if @stopped.value

            changed = (modified + added + removed).any? do |p|
              File.dirname(p) == real_directory && watched_name?(real_directory, File.basename(p))
            end
            @on_change.call if changed && !@stopped.value
          end
          listener.start
          -> { listener.stop }
        end

        #
        # Returns true if the name is one of the configured files in the watched real directory.
        #
        private def watched_name?(real_directory, name)
          @lock.synchronize do
            entry = @watched[real_directory]
            !entry.nil? && entry.names.include?(name)
          end
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
        # Runs an inotify notifier on its own thread, takes watches for it over time, and stops it
        # on request.
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
          # Adds a watch on a directory and returns the notifier's watch object, whose `close`
          # removes the watch again.
          #
          def watch(directory, &callback)
            @notifier.watch(directory, *INOTIFY_EVENTS, &callback)
          end

          #
          # Stops the notifier and waits briefly for its thread. Closing the notifier ends the
          # blocking read that the thread is in. A callback can call this on the notifier's own
          # thread, which then ends when the callback returns.
          #
          def stop
            @notifier.stop
            @notifier.close
            @thread.join(2) unless Thread.current == @thread
          end
        end
        private_constant :InotifyListener
      end
    end
  end
end
