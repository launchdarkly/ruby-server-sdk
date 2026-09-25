# frozen_string_literal: true

require 'ldclient-rb/impl/file_data'
require 'ldclient-rb/impl/util'
require 'ldclient-rb/interfaces/data_system'
require 'ldclient-rb/util'

require 'thread'

module LaunchDarkly
  module Impl
    module Integrations
      #
      # Internal implementation of both Initializer and Synchronizer protocols for file-based data.
      #
      # This component reads feature flag and segment data from local files and provides them
      # via the FDv2 protocol interfaces. Each instance implements both Initializer and Synchronizer
      # protocols:
      # - As an Initializer: reads files once and returns initial data
      # - As a Synchronizer: watches for file changes and yields updates
      #
      # The files use the same format as the v1 file data source, supporting flags, flagValues,
      # and segments in JSON or YAML format. Every configured file must exist. A key that appears
      # in more than one file is an error.
      #
      # File reading, parsing, merging, and reloading are shared with the other file-based
      # components. See {LaunchDarkly::Impl::FileData}.
      #
      class FileDataSourceV2
        include LaunchDarkly::Interfaces::DataSystem::Initializer
        include LaunchDarkly::Interfaces::DataSystem::Synchronizer

        #
        # Initialize the file data source.
        #
        # @param logger [Logger] the logger
        # @param paths [Array<String>, String] file paths to load (or a single path string)
        # @param poll_interval [Float] seconds between polling checks when watching files (default: 1).
        #   Used only when the native file-watching mechanism from the `listen` gem is not available.
        #
        def initialize(logger, paths:, poll_interval: 1)
          @logger = logger
          @paths = FileData.absolute_paths(paths)
          @poll_interval = poll_interval

          @closed = false
          @update_queue = Queue.new
          @lock = Mutex.new
          @reloader = nil
          @change_detector = nil
        end

        #
        # Return the name of this data source.
        #
        # @return [String]
        #
        def name
          'FileDataV2'
        end

        #
        # Implementation of the Initializer.fetch method.
        #
        # Reads all configured files once and returns their contents as a Basis.
        # File-based data sources never request the FDv1 Fallback Directive,
        # so the returned {FetchResult} always reports `fallback_to_fdv1: false`.
        #
        # @param selector_store [LaunchDarkly::Interfaces::DataSystem::SelectorStore] Provides the Selector (unused for file data)
        # @return [LaunchDarkly::Interfaces::DataSystem::FetchResult]
        #
        def fetch(selector_store)
          result =
            begin
              @lock.synchronize do
                if @closed
                  next LaunchDarkly::Result.fail('FileDataV2 source has been closed')
                end

                merged = load_all
                basis = LaunchDarkly::Interfaces::DataSystem::Basis.new(
                  change_set: make_change_set(merged),
                  persist: false,
                  environment_id: nil
                )

                LaunchDarkly::Result.success(basis)
              end
            rescue FileData::ReadError, FileData::MergeError => e
              @logger.error { "[LDClient] Unable to load flag data: #{e.message}" }
              LaunchDarkly::Result.fail("Unable to load flag data: #{e.message}", e)
            rescue => e
              @logger.error { "[LDClient] Error fetching file data: #{e.message}" }
              LaunchDarkly::Result.fail("Error fetching file data: #{e.message}", e)
            end

          LaunchDarkly::Interfaces::DataSystem::FetchResult.new(result: result, fallback_to_fdv1: false)
        end

        #
        # Implementation of the Synchronizer.sync method.
        #
        # Yields initial data from files, then continues to watch for file changes
        # and yields updates when files are modified. A reload that fails, for example because a
        # file was observed while still being written, yields an interrupted status and keeps the
        # last good data. The reload is retried, and the next success yields a valid status again.
        #
        # @param selector_store [LaunchDarkly::Interfaces::DataSystem::SelectorStore] Provides the Selector (unused for file data)
        # @yield [LaunchDarkly::Interfaces::DataSystem::Update] Yields Update objects as synchronization progresses
        # @return [void]
        #
        def sync(selector_store)
          # First yield initial data
          initial_fetch = fetch(selector_store)
          unless initial_fetch.success?
            yield LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
              error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA,
                0,
                initial_fetch.error,
                Time.now
              )
            )
            return
          end

          yield LaunchDarkly::Interfaces::DataSystem::Update.new(
            state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
            change_set: initial_fetch.value.change_set
          )

          # Start watching for file changes
          @lock.synchronize do
            start_change_detection unless @closed
          end

          until @closed
            begin
              update = @update_queue.pop

              # stop() pushes nil to wake us up when shutting down
              break if update.nil?

              yield update
            rescue => e
              yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
                error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                  LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN,
                  0,
                  "Error in file data synchronizer: #{e.message}",
                  Time.now
                )
              )
              break
            end
          end
        end

        #
        # Stop the data source and clean up resources.
        #
        # @return [void]
        #
        def stop
          reloader = nil
          change_detector = nil
          @lock.synchronize do
            return if @closed
            @closed = true

            reloader = @reloader
            change_detector = @change_detector
            @reloader = nil
            @change_detector = nil
          end

          change_detector&.stop
          reloader&.stop

          # Signal shutdown to sync generator
          @update_queue.push(nil)
        end

        #
        # Reads and merges all configured files.
        #
        # @return [LaunchDarkly::Impl::FileData::MergeResult]
        # @raise [LaunchDarkly::Impl::FileData::ReadError] if a file cannot be read or parsed
        # @raise [LaunchDarkly::Impl::FileData::MergeError] if the files cannot be combined
        #
        private def load_all
          documents = @paths.map { |path| FileData::Document.read(path) }
          FileData.merge(documents, duplicate_keys_handling: FileData::DuplicateKeysHandling::FAIL, logger: @logger)
        end

        #
        # Builds a full-transfer change set from merged file data.
        #
        # @param merged [LaunchDarkly::Impl::FileData::MergeResult]
        # @return [LaunchDarkly::Interfaces::DataSystem::ChangeSet]
        #
        private def make_change_set(merged)
          builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
          builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)

          merged.flags.each do |key, flag|
            builder.add_put(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG, key, flag.version, flag)
          end

          merged.segments.each do |key, segment|
            builder.add_put(LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT, key, segment.version, segment)
          end

          # Use no_selector since we don't have versioning information from files
          builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)
        end

        #
        # Starts the reloader and the change detector. The native file-watching mechanism from the
        # `listen` gem is used when that gem is available. Otherwise the files are polled.
        #
        private def start_change_detection
          @reloader = FileData::Reloader.new(
            paths: @paths,
            logger: @logger,
            apply: method(:on_reload_applied),
            on_error: method(:on_reload_failed),
            skip_unchanged: true
          )
          trigger = @reloader.method(:trigger)
          @change_detector =
            if FileData::Watcher.available?
              FileData::Watcher.new(@paths, trigger, @logger)
            else
              FileData::Poller.new(@paths, @poll_interval, trigger, @logger)
            end
        end

        #
        # Queues a valid update carrying the reloaded data.
        #
        # @param merged [LaunchDarkly::Impl::FileData::MergeResult]
        #
        private def on_reload_applied(merged)
          return if @closed

          @update_queue.push(LaunchDarkly::Interfaces::DataSystem::Update.new(
            state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
            change_set: make_change_set(merged)
          ))
        end

        #
        # Queues an interrupted status. The store keeps the last good data.
        #
        # @param error [StandardError]
        #
        private def on_reload_failed(error)
          return if @closed

          @update_queue.push(LaunchDarkly::Interfaces::DataSystem::Update.new(
            state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
            error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
              LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA,
              0,
              error.message,
              Time.now
            )
          ))
        end
      end
    end
  end
end
