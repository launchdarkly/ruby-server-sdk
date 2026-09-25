require 'ldclient-rb/in_memory_store'
require 'ldclient-rb/impl/file_data'
require 'ldclient-rb/impl/util'

require 'concurrent/atomics'

module LaunchDarkly
  module Impl
    module Integrations
      #
      # The FDv1 file data source. Every configured file must exist. A key that appears in more
      # than one file is an error. File reading, parsing, merging, and reloading are shared with
      # the other file-based components. See {LaunchDarkly::Impl::FileData}.
      #
      class FileDataSourceImpl
        #
        # @param data_store [LaunchDarkly::Interfaces::FeatureStore]
        # @param data_source_update_sink [LaunchDarkly::Interfaces::DataSource::UpdateSink, nil] Might be nil for backwards compatibility reasons.
        # @param logger [Logger]
        # @param options [Hash]
        #
        def initialize(data_store, data_source_update_sink, logger, options={})
          @data_store = data_source_update_sink || data_store
          @data_source_update_sink = data_source_update_sink
          @logger = logger
          @paths = FileData.absolute_paths(options[:paths] || [])
          @auto_update = options[:auto_update]
          # To avoid pulling in 'listen' and its transitive dependencies for people who aren't using the
          # file data source or who don't need auto-updating, the native file-watching mechanism is used
          # only if the host app has provided the 'listen' gem.
          @use_listen = @auto_update && FileData::Watcher.available? && !options[:force_polling]
          @poll_interval = options[:poll_interval] || 1
          @initialized = Concurrent::AtomicBoolean.new(false)

          # Every load stamps a version that is higher than the previous load's, so that a reload
          # is seen as a change by anything that compares versions.
          @version_lock = Mutex.new
          @last_version = 0

          @reloader = FileData::Reloader.new(
            paths: @paths,
            logger: @logger,
            apply: method(:apply_data),
            on_error: method(:report_failure),
            skip_unchanged: true,
            next_version: method(:next_version)
          )
          @change_detector = nil
        end

        def initialized?
          @initialized.value
        end

        def start
          ready = Concurrent::Event.new

          # We will return immediately regardless of whether the file load succeeded or failed -
          # the difference can be detected by checking "initialized?"
          ready.set

          @reloader.reload_now

          if @auto_update
            trigger = @reloader.method(:trigger)
            @change_detector =
              if @use_listen
                FileData::Watcher.new(@paths, trigger, @logger)
              else
                FileData::Poller.new(@paths, @poll_interval, trigger, @logger)
              end
          end

          ready
        end

        def stop
          @change_detector&.stop
          @reloader.stop
        end

        private def next_version
          @version_lock.synchronize { @last_version += 1 }
        end

        #
        # Replaces the store contents with the merged file data.
        #
        # @param merged [LaunchDarkly::Impl::FileData::MergeResult]
        #
        private def apply_data(merged)
          all_data = {
            Impl::DataStore::FEATURES => merged.flags,
            Impl::DataStore::SEGMENTS => merged.segments,
          }
          @data_store.init(all_data)
          @data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
          @initialized.make_true
        end

        #
        # Reports a failed load. The reloader logs the failure and keeps the last good data.
        #
        # @param error [StandardError]
        #
        private def report_failure(error)
          @data_source_update_sink&.update_status(
            LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
            LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
              LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA, 0, error.message, Time.now
            )
          )
        end
      end
    end
  end
end
