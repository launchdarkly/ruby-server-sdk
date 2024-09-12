require 'ldclient-rb/in_memory_store'
require 'ldclient-rb/util'

require 'concurrent/atomics'
require 'json'
require 'yaml'
require 'pathname'

module LaunchDarkly
  module Impl
    module Integrations
      class FileDataSourceImpl
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
        # @param data_store [LaunchDarkly::Interfaces::FeatureStore]
        # @param data_source_update_sink [LaunchDarkly::Interfaces::DataSource::UpdateSink, nil] Might be nil for backwards compatibility reasons.
        # @param logger [Logger]
        # @param options [Hash]
        #
        def initialize(data_store, data_source_update_sink, logger, options={})
          @data_store = data_source_update_sink || data_store
          @data_source_update_sink = data_source_update_sink
          @logger = logger
          @paths = options[:paths] || []
          if @paths.is_a? String
            @paths = [ @paths ]
          end
          @allow_duplicates = options[:allow_duplicates] || false
          @auto_update = options[:auto_update]
          @use_listen = @auto_update && @@have_listen && !options[:force_polling]
          @poll_interval = options[:poll_interval] || 1
          @initialized = Concurrent::AtomicBoolean.new(false)
          @ready = Concurrent::Event.new

          @version_lock = Mutex.new
          @last_version = 1
        end

        def initialized?
          @initialized.value
        end

        def start
          ready = Concurrent::Event.new

          # We will return immediately regardless of whether the file load succeeded or failed -
          # the difference can be detected by checking "initialized?"
          ready.set

          load_all

          if @auto_update
            # If we're going to watch files, then the start event will be set the first time we get
            # a successful load.
            @listener = start_listener
          end

          ready
        end

        def stop
          @listener.stop unless @listener.nil?
        end

        private

        def load_all
          all_data = {
            FEATURES => {},
            SEGMENTS => {},
          }
          @paths.each do |path|
            begin
              load_file(path, all_data)
            rescue => exn
              LaunchDarkly::Util.log_exception(@logger, "Unable to load flag data from \"#{path}\"", exn)
              @data_source_update_sink&.update_status(
                LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED,
                LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA, 0, exn.to_s, Time.now)
              )
              return
            end
          end
          @data_store.init(all_data)
          @data_source_update_sink&.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
          @initialized.make_true
        end

        def load_file(path, all_data)
          version = 1
          @version_lock.synchronize {
            version = @last_version
            @last_version += 1
          }

          parsed = parse_content(IO.read(path))
          (parsed[:flags] || {}).each do |key, flag|
            flag[:version] = version
            add_item(all_data, FEATURES, flag)
          end
          (parsed[:flagValues] || {}).each do |key, value|
            add_item(all_data, FEATURES, make_flag_with_value(key.to_s, value, version))
          end
          (parsed[:segments] || {}).each do |key, segment|
            segment[:version] = version
            add_item(all_data, SEGMENTS, segment)
          end
        end

        def parse_content(content)
          # We can use the Ruby YAML parser for both YAML and JSON (JSON is a subset of YAML and while
          # not all YAML parsers handle it correctly, we have verified that the Ruby one does, at least
          # for all the samples of actual flag data that we've tested).
          symbolize_all_keys(YAML.safe_load(content))
        end

        def symbolize_all_keys(value)
          # This is necessary because YAML.load doesn't have an option for parsing keys as symbols, and
          # the SDK expects all objects to be formatted that way.
          if value.is_a?(Hash)
            value.map{ |k, v| [k.to_sym, symbolize_all_keys(v)] }.to_h
          elsif value.is_a?(Array)
            value.map{ |v| symbolize_all_keys(v) }
          else
            value
          end
        end

        def add_item(all_data, kind, item)
          items = all_data[kind]
          raise ArgumentError, "Received unknown item kind #{kind[:namespace]} in add_data" if items.nil? # shouldn't be possible since we preinitialize the hash
          key = item[:key].to_sym
          unless items[key].nil? || @allow_duplicates
            raise ArgumentError, "#{kind[:namespace]} key \"#{item[:key]}\" was used more than once"
          end
          items[key] = Model.deserialize(kind, item)
        end

        def make_flag_with_value(key, value, version)
          {
            key: key,
            on: true,
            version: version,
            fallthrough: { variation: 0 },
            variations: [ value ],
          }
        end

        def start_listener
          resolved_paths = @paths.map { |p| Pathname.new(File.absolute_path(p)).realpath.to_s }
          if @use_listen
            start_listener_with_listen_gem(resolved_paths)
          else
            FileDataSourcePoller.new(resolved_paths, @poll_interval, self.method(:load_all), @logger)
          end
        end

        def start_listener_with_listen_gem(resolved_paths)
          path_set = resolved_paths.to_set
          dir_paths = resolved_paths.map{ |p| File.dirname(p) }.uniq
          opts = { latency: @poll_interval }
          l = Listen.to(*dir_paths, opts) do |modified, added, removed|
            paths = modified + added + removed
            if paths.any? { |p| path_set.include?(p) }
              load_all
            end
          end
          l.start
          l
        end

        #
        # Used internally by FileDataSource to track data file changes if the 'listen' gem is not available.
        #
        class FileDataSourcePoller
          def initialize(resolved_paths, interval, reloader, logger)
            @stopped = Concurrent::AtomicBoolean.new(false)
            get_file_times = Proc.new do
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
              while true
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
                  reloader.call if changed
                rescue => exn
                  LaunchDarkly::Util.log_exception(logger, "Unexpected exception in FileDataSourcePoller", exn)
                end
              end
            end
          end

          def stop
            @stopped.make_true
            @thread.run  # wakes it up if it's sleeping
          end
        end
      end
    end
  end
end
