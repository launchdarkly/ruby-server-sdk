require 'concurrent/atomics'
require 'json'
require 'yaml'
require 'listen'
require 'pathname'

module LaunchDarkly

  #
  # Provides a way to use local files as a source of feature flag state. This would typically be
  # used in a test environment, to operate using a predetermined feature flag state without an
  # actual LaunchDarkly connection.
  #
  # To use this component, call `FileDataSource.factory`, and store its return value in the
  # `update_processor_factory` property of your LaunchDarkly client configuration. In the options
  # to `factory`, set `paths` to the file path(s) of your data file(s):
  #
  #     config.update_processor_factory = FileDataSource.factory(paths: [ myFilePath ])
  #
  # This will cause the client not to connect to LaunchDarkly to get feature flags. The
  # client may still make network connections to send analytics events, unless you have disabled
  # this with Config.send_events or Config.offline.
  #
  # Flag data files can be either JSON or YAML. They contain an object with three possible
  # properties:
  #
  # - "flags": Feature flag definitions.
  # - "flagValues": Simplified feature flags that contain only a value.
  # - "segments": User segment definitions.
  #
  # The format of the data in "flags" and "segments" is defined by the LaunchDarkly application
  # and is subject to change. Rather than trying to construct these objects yourself, it is simpler
  # to request existing flags directly from the LaunchDarkly server in JSON format, and use this
  # output as the starting point for your file. In Linux you would do this:
  #
  #    curl -H "Authorization: {your sdk key}" https://app.launchdarkly.com/sdk/latest-all
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
    def self.factory(options={})
      return Proc.new do |sdk_key, config|
        FileDataSourceImpl.new(config.feature_store, config.logger, options)
      end
    end
  end

  class FileDataSourceImpl
    def initialize(feature_store, logger, options={})
      @feature_store = feature_store
      @logger = logger
      @paths = options[:paths] || []
      @auto_update = options[:auto_update]
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
      parsed = parse_content(IO.read(path))
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
      if content.strip.start_with?("{")
        JSON.parse(content, symbolize_names: true)
      else
        symbolize_all_keys(YAML.load(content))
      end
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
      items = all_data[kind] || {}
      if !items[item[:key]].nil?
        raise ArgumentError, "#{kind[:namespace]} key \"#{item[:key]}\" was used more than once"
      end
      items[item[:key]] = item
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
      path_set = resolved_paths.to_set
      dir_paths = resolved_paths.map{ |p| File.dirname(p) }.uniq
      l = Listen.to(*dir_paths) do |modified, added, removed|
        paths = modified + added + removed
        if paths.any? { |p| path_set.include?(p) }
          load_all
        end
      end
      l.start
      l
    end
  end
end
