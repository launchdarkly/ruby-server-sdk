# frozen_string_literal: true

require 'ldclient-rb/impl/util'
require 'ldclient-rb/interfaces/data_system'
require 'ldclient-rb/util'

require 'concurrent/atomics'
require 'json'
require 'yaml'
require 'pathname'
require 'thread'

module LaunchDarkly
  module Impl
    module Integrations
      #
      # Internal implementation of both Initializer and Synchronizer protocols for file-based data.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      # This component reads feature flag and segment data from local files and provides them
      # via the FDv2 protocol interfaces. Each instance implements both Initializer and Synchronizer
      # protocols:
      # - As an Initializer: reads files once and returns initial data
      # - As a Synchronizer: watches for file changes and yields updates
      #
      # The files use the same format as the v1 file data source, supporting flags, flagValues,
      # and segments in JSON or YAML format.
      #
      class FileDataSourceV2
        include LaunchDarkly::Interfaces::DataSystem::Initializer
        include LaunchDarkly::Interfaces::DataSystem::Synchronizer

        # To avoid pulling in 'listen' and its transitive dependencies for people who aren't using the
        # file data source or who don't need auto-updating, we only enable auto-update if the 'listen'
        # gem has been provided by the host app.
        @@have_listen = false
        begin
          require 'listen'
          @@have_listen = true
        rescue LoadError
          # Ignored
        end

        #
        # Initialize the file data source.
        #
        # @param logger [Logger] the logger
        # @param paths [Array<String>, String] file paths to load (or a single path string)
        # @param poll_interval [Float] seconds between polling checks when watching files (default: 1)
        # @param force_polling [Boolean] force polling even if listen gem is available (default: false)
        #
        def initialize(logger, paths:, poll_interval: 1, force_polling: false)
          @logger = logger
          @paths = paths.is_a?(Array) ? paths : [paths]
          @poll_interval = poll_interval
          @force_polling = force_polling
          @use_listen = @@have_listen && !@force_polling

          @closed = false
          @update_queue = Queue.new
          @lock = Mutex.new
          @listener = nil
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
        #
        # @param selector_store [LaunchDarkly::Interfaces::DataSystem::SelectorStore] Provides the Selector (unused for file data)
        # @return [LaunchDarkly::Result] A Result containing either a Basis or an error message
        #
        def fetch(selector_store)
          @lock.synchronize do
            if @closed
              return LaunchDarkly::Result.fail('FileDataV2 source has been closed')
            end

            result = load_all_to_changeset
            return result unless result.success?

            change_set = result.value
            basis = LaunchDarkly::Interfaces::DataSystem::Basis.new(
              change_set: change_set,
              persist: false,
              environment_id: nil
            )

            LaunchDarkly::Result.success(basis)
          end
        rescue => e
          @logger.error { "[LDClient] Error fetching file data: #{e.message}" }
          LaunchDarkly::Result.fail("Error fetching file data: #{e.message}", e)
        end

        #
        # Implementation of the Synchronizer.sync method.
        #
        # Yields initial data from files, then continues to watch for file changes
        # and yields updates when files are modified.
        #
        # @param selector_store [LaunchDarkly::Interfaces::DataSystem::SelectorStore] Provides the Selector (unused for file data)
        # @yield [LaunchDarkly::Interfaces::DataSystem::Update] Yields Update objects as synchronization progresses
        # @return [void]
        #
        def sync(selector_store)
          # First yield initial data
          initial_result = fetch(selector_store)
          unless initial_result.success?
            yield LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
              error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA,
                0,
                initial_result.error,
                Time.now
              )
            )
            return
          end

          yield LaunchDarkly::Interfaces::DataSystem::Update.new(
            state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
            change_set: initial_result.value.change_set
          )

          # Start watching for file changes
          @lock.synchronize do
            @listener = start_listener unless @closed
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
          @lock.synchronize do
            return if @closed
            @closed = true

            listener = @listener
            @listener = nil

            listener&.stop
          end

          # Signal shutdown to sync generator
          @update_queue.push(nil)
        end

        private

        #
        # Load all files and build a changeset.
        #
        # @return [LaunchDarkly::Result] A Result containing either a ChangeSet or an error message
        #
        def load_all_to_changeset
          flags_dict = {}
          segments_dict = {}

          @paths.each do |path|
            begin
              load_file(path, flags_dict, segments_dict)
            rescue => e
              Impl::Util.log_exception(@logger, "Unable to load flag data from \"#{path}\"", e)
              return LaunchDarkly::Result.fail("Unable to load flag data from \"#{path}\": #{e.message}", e)
            end
          end

          builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
          builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)

          flags_dict.each do |key, flag_data|
            builder.add_put(
              LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
              key,
              flag_data[:version] || 1,
              flag_data
            )
          end

          segments_dict.each do |key, segment_data|
            builder.add_put(
              LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT,
              key,
              segment_data[:version] || 1,
              segment_data
            )
          end

          # Use no_selector since we don't have versioning information from files
          change_set = builder.finish(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector)

          LaunchDarkly::Result.success(change_set)
        end

        #
        # Load a single file and add its contents to the provided dictionaries.
        #
        # @param path [String] path to the file
        # @param flags_dict [Hash] dictionary to add flags to
        # @param segments_dict [Hash] dictionary to add segments to
        #
        def load_file(path, flags_dict, segments_dict)
          parsed = parse_content(File.read(path))

          (parsed[:flags] || {}).each do |key, flag|
            flag[:version] ||= 1
            add_item(flags_dict, 'flags', flag)
          end

          (parsed[:flagValues] || {}).each do |key, value|
            add_item(flags_dict, 'flags', make_flag_with_value(key.to_s, value))
          end

          (parsed[:segments] || {}).each do |key, segment|
            segment[:version] ||= 1
            add_item(segments_dict, 'segments', segment)
          end
        end

        #
        # Parse file content as JSON or YAML.
        #
        # @param content [String] file content string
        # @return [Hash] parsed dictionary with symbolized keys
        #
        def parse_content(content)
          # Ruby's YAML parser correctly handles JSON as well
          symbolize_all_keys(YAML.safe_load(content))
        end

        #
        # Recursively symbolize all keys in a hash or array.
        #
        # @param value [Object] the value to symbolize
        # @return [Object] the value with all keys symbolized
        def symbolize_all_keys(value)
          if value.is_a?(Hash)
            value.map { |k, v| [k.to_sym, symbolize_all_keys(v)] }.to_h
          elsif value.is_a?(Array)
            value.map { |v| symbolize_all_keys(v) }
          else
            value
          end
        end

        #
        # Add an item to a dictionary, checking for duplicates.
        #
        # @param items_dict [Hash] dictionary to add to
        # @param kind_name [String] name of the kind (for error messages)
        # @param item [Hash] item to add
        #
        def add_item(items_dict, kind_name, item)
          key = item[:key].to_sym
          if items_dict[key].nil?
            items_dict[key] = item
          else
            raise ArgumentError, "In #{kind_name}, key \"#{item[:key]}\" was used more than once"
          end
        end

        #
        # Create a simple flag configuration from a key-value pair.
        #
        # @param key [String] flag key
        # @param value [Object] flag value
        # @return [Hash] flag dictionary
        #
        def make_flag_with_value(key, value)
          {
            key: key,
            on: true,
            version: 1,
            fallthrough: { variation: 0 },
            variations: [value],
          }
        end

        #
        # Callback invoked when files change.
        #
        # Reloads all files and queues an update.
        #
        def on_file_change
          @lock.synchronize do
            return if @closed

            begin
              result = load_all_to_changeset

              if result.success?
                update = LaunchDarkly::Interfaces::DataSystem::Update.new(
                  state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
                  change_set: result.value
                )
                @update_queue.push(update)
              else
                error_update = LaunchDarkly::Interfaces::DataSystem::Update.new(
                  state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                  error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                    LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA,
                    0,
                    result.error,
                    Time.now
                  )
                )
                @update_queue.push(error_update)
              end
            rescue => e
              @logger.error { "[LDClient] Error processing file change: #{e.message}" }
              error_update = LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                  LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN,
                  0,
                  "Error processing file change: #{e.message}",
                  Time.now
                )
              )
              @update_queue.push(error_update)
            end
          end
        end

        #
        # Start watching files for changes.
        #
        # @return [Object] auto-updater instance
        #
        def start_listener
          resolved_paths = @paths.map do |p|
            begin
              Pathname.new(File.absolute_path(p)).realpath.to_s
            rescue
              @logger.warn { "[LDClient] Cannot watch for changes to data file \"#{p}\" because it is an invalid path" }
              nil
            end
          end.compact

          if @use_listen
            start_listener_with_listen_gem(resolved_paths)
          else
            FileDataSourcePollerV2.new(resolved_paths, @poll_interval, method(:on_file_change), @logger)
          end
        end

        #
        # Start listening for file changes using the listen gem.
        #
        # @param resolved_paths [Array<String>] resolved file paths to watch
        # @return [Listen::Listener] the listener instance
        #
        def start_listener_with_listen_gem(resolved_paths)
          path_set = resolved_paths.to_set
          dir_paths = resolved_paths.map { |p| File.dirname(p) }.uniq
          opts = { latency: @poll_interval }
          l = Listen.to(*dir_paths, **opts) do |modified, added, removed|
            paths = modified + added + removed
            if paths.any? { |p| path_set.include?(p) }
              on_file_change
            end
          end
          l.start
          l
        end
      end

      #
      # Used internally by FileDataSourceV2 to track data file changes if the 'listen' gem is not available.
      #
      class FileDataSourcePollerV2
        #
        # Initialize the file data poller.
        #
        # @param resolved_paths [Array<String>] resolved file paths to watch
        # @param interval [Float] polling interval in seconds
        # @param on_change_callback [Proc] callback to invoke when files change
        # @param logger [Logger] the logger
        #
        def initialize(resolved_paths, interval, on_change_callback, logger)
          @stopped = Concurrent::AtomicBoolean.new(false)
          @on_change = on_change_callback
          @logger = logger

          get_file_times = proc do
            ret = {}
            resolved_paths.each do |path|
              begin
                ret[path] = File.mtime(path)
              rescue Errno::ENOENT
                ret[path] = nil
              end
            end
            ret
          end

          last_times = get_file_times.call
          @thread = Thread.new do
            loop do
              sleep interval
              break if @stopped.value

              begin
                new_times = get_file_times.call
                changed = false
                last_times.each do |path, old_time|
                  new_time = new_times[path]
                  if !new_time.nil? && new_time != old_time
                    changed = true
                    break
                  end
                end
                last_times = new_times
                @on_change.call if changed
              rescue => e
                Impl::Util.log_exception(@logger, "Unexpected exception in FileDataSourcePollerV2", e)
              end
            end
          end
          @thread.name = "LD/FileDataSourceV2"
        end

        def stop
          @stopped.make_true
          @thread.run # wakes it up if it's sleeping
        end
      end
    end
  end
end
