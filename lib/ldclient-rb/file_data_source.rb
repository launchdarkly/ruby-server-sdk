require 'concurrent/atomics'
require 'json'
require 'yaml'
require 'pathname'

module LaunchDarkly
  # To avoid pulling in 'listen' and its transitive dependencies for people who aren't using the
  # file data source or who don't need auto-updating, we only enable auto-update if the 'listen'
  # gem has been provided by the host app.
  # @private
  @@have_listen = false
  begin
    require 'listen'
    @@have_listen = true
  rescue LoadError
  end

  @@have_erb = false
  begin
    require 'erb'
    @@have_erb = true
  rescue LoadError
  end

  # @private
  def self.have_listen?
    @@have_listen
  end

  def self.have_erb?
    @@have_erb
  end
  #
  # Provides a way to use local files as a source of feature flag state. This allows using a
  # predetermined feature flag state without an actual LaunchDarkly connection.
  #
  # Reading flags from a file is only intended for pre-production environments. Production
  # environments should always be configured to receive flag updates from LaunchDarkly.
  #
  # To use this component, call {FileDataSource#factory}, and store its return value in the
  # {Config#data_source} property of your LaunchDarkly client configuration. In the options
  # to `factory`, set `paths` to the file path(s) of your data file(s):
  #
  #     file_source = FileDataSource.factory(paths: [ myFilePath ])
  #     config = LaunchDarkly::Config.new(data_source: file_source)
  #
  # This will cause the client not to connect to LaunchDarkly to get feature flags. The
  # client may still make network connections to send analytics events, unless you have disabled
  # this with {Config#send_events} or {Config#offline?}.
  #
  # Flag data files can be either JSON or YAML. They contain an object with three possible
  # properties:
  #
  # - `flags`: Feature flag definitions.
  # - `flagValues`: Simplified feature flags that contain only a value.
  # - `segments`: User segment definitions.
  #
  # The format of the data in `flags` and `segments` is defined by the LaunchDarkly application
  # and is subject to change. Rather than trying to construct these objects yourself, it is simpler
  # to request existing flags directly from the LaunchDarkly server in JSON format, and use this
  # output as the starting point for your file. In Linux you would do this:
  #
  # ```
  #     curl -H "Authorization: YOUR_SDK_KEY" https://sdk.launchdarkly.com/sdk/latest-all
  # ```
  #
  # The output will look something like this (but with many more properties):
  #
  #     {
  #       "flags": {
  #         "flag-key-1": {
  #           "key": "flag-key-1",
  #           "on": true,
  #           "variations": [ "a", "b" ]
  #         }
  #       },
  #       "segments": {
  #         "segment-key-1": {
  #           "key": "segment-key-1",
  #           "includes": [ "user-key-1" ]
  #         }
  #       }
  #     }
  #
  # Data in this format allows the SDK to exactly duplicate all the kinds of flag behavior supported
  # by LaunchDarkly. However, in many cases you will not need this complexity, but will just want to
  # set specific flag keys to specific values. For that, you can use a much simpler format:
  #
  #     {
  #       "flagValues": {
  #         "my-string-flag-key": "value-1",
  #         "my-boolean-flag-key": true,
  #         "my-integer-flag-key": 3
  #       }
  #     }
  #
  # Or, in YAML:
  #
  #     flagValues:
  #       my-string-flag-key: "value-1"
  #       my-boolean-flag-key: true
  #       my-integer-flag-key: 1
  #
  # It is also possible to specify both "flags" and "flagValues", if you want some flags
  # to have simple values and others to have complex behavior. However, it is an error to use the
  # same flag key or segment key more than once, either in a single file or across multiple files.
  #
  # If the data source encounters any error in any file-- malformed content, a missing file, or a
  # duplicate key-- it will not load flags from any of the files.      
  #
  class FileDataSource
    #
    # Returns a factory for the file data source component.
    #
    # @param options [Hash] the configuration options
    # @option options [Array] :paths  The paths of the source files for loading flag data. These
    #   may be absolute paths or relative to the current working directory.
    # @option options [Boolean] :auto_update  True if the data source should watch for changes to
    #   the source file(s) and reload flags whenever there is a change. Auto-updating will only
    #   work if all of the files you specified have valid directory paths at startup time.
    #   Note that the default implementation of this feature is based on polling the filesystem,
    #   which may not perform well. If you install the 'listen' gem (not included by default, to
    #   avoid adding unwanted dependencies to the SDK), its native file watching mechanism will be
    #   used instead. However, 'listen' will not be used in JRuby 9.1 due to a known instability.
    # @option options [Float] :poll_interval  The minimum interval, in seconds, between checks for
    #   file modifications - used only if auto_update is true, and if the native file-watching
    #   mechanism from 'listen' is not being used. The default value is 1 second.
    # @return an object that can be stored in {Config#data_source}
    #
    def self.factory(options={})
      return lambda { |sdk_key, config| FileDataSourceImpl.new(config.feature_store, config.logger, options) }
    end
  end

  # @private
  class FileDataSourceImpl
    def initialize(feature_store, logger, options={})
      @feature_store = feature_store
      @logger = logger
      @paths = options[:paths] || []
      if @paths.is_a? String
        @paths = [ @paths ]
      end
      @auto_update = options[:auto_update]
      if @auto_update && LaunchDarkly.have_listen? && !options[:force_polling] # force_polling is used only for tests
        # We have seen unreliable behavior in the 'listen' gem in JRuby 9.1 (https://github.com/guard/listen/issues/449).
        # Therefore, on that platform we'll fall back to file polling instead.
        if defined?(JRUBY_VERSION) && JRUBY_VERSION.start_with?("9.1.")
          @use_listen = false
        else
          @use_listen = true
        end
      end
      @poll_interval = options[:poll_interval] || 1
      @initialized = Concurrent::AtomicBoolean.new(false)
      @ready = Concurrent::Event.new
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
      @listener.stop if !@listener.nil?
    end

    private

    def load_all
      all_data = {
        FEATURES => {},
        SEGMENTS => {}
      }
      @paths.each do |path|
        begin
          load_file(path, all_data)
        rescue => exn
          Util.log_exception(@logger, "Unable to load flag data from \"#{path}\"", exn)
          return
        end
      end
      @feature_store.init(all_data)
      @initialized.make_true
    end

    def load_file(path, all_data)
      content = IO.read(path)
      content = ERB.new(content).result if LaunchDarkly.have_erb?
      parsed = parse_content(content)
      (parsed[:flags] || {}).each do |key, flag|
        add_item(all_data, FEATURES, flag)
      end
      (parsed[:flagValues] || {}).each do |key, value|
        add_item(all_data, FEATURES, make_flag_with_value(key.to_s, value))
      end
      (parsed[:segments] || {}).each do |key, segment|
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
      raise ArgumentError, "Received unknown item kind #{kind} in add_data" if items.nil? # shouldn't be possible since we preinitialize the hash
      key = item[:key].to_sym
      if !items[key].nil?
        raise ArgumentError, "#{kind[:namespace]} key \"#{item[:key]}\" was used more than once"
      end
      items[key] = item
    end

    def make_flag_with_value(key, value)
      {
        key: key,
        on: true,
        fallthrough: { variation: 0 },
        variations: [ value ]
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
              Util.log_exception(logger, "Unexpected exception in FileDataSourcePoller", exn)
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
