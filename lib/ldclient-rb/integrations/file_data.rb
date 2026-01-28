require 'ldclient-rb/impl/integrations/file_data_source'
require 'ldclient-rb/impl/integrations/file_data_source_v2'

module LaunchDarkly
  module Integrations
    #
    # Provides a way to use local files as a source of feature flag state. This allows using a
    # predetermined feature flag state without an actual LaunchDarkly connection.
    #
    # Reading flags from a file is only intended for pre-production environments. Production
    # environments should always be configured to receive flag updates from LaunchDarkly.
    #
    # To use this component, call {FileData#data_source}, and store its return value in the
    # {Config#data_source} property of your LaunchDarkly client configuration. In the options
    # to `data_source`, set `paths` to the file path(s) of your data file(s):
    #
    #     file_source = LaunchDarkly::Integrations::FileData.data_source(paths: [ myFilePath ])
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
    # - `segments`: Context segment definitions.
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
    module FileData
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
      #   used instead.
      # @option options [Float] :poll_interval  The minimum interval, in seconds, between checks for
      #   file modifications - used only if auto_update is true, and if the native file-watching
      #   mechanism from 'listen' is not being used. The default value is 1 second.
      # @return an object that can be stored in {Config#data_source}
      #
      def self.data_source(options={})
        lambda { |sdk_key, config|
          Impl::Integrations::FileDataSourceImpl.new(config.feature_store, config.data_source_update_sink, config.logger, options) }
      end

      #
      # Returns a builder for the FDv2-compatible file data source.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      # This method returns a builder proc that can be used with the FDv2 data system
      # configuration as both an Initializer and a Synchronizer. When used as an Initializer
      # (via `fetch`), it reads files once. When used as a Synchronizer (via `sync`), it
      # watches for file changes and automatically updates when files are modified.
      #
      # @param options [Hash] the configuration options
      # @option options [Array<String>, String] :paths  The paths of the source files for loading flag data. These
      #   may be absolute paths or relative to the current working directory. (Required)
      # @option options [Float] :poll_interval  The minimum interval, in seconds, between checks for
      #   file modifications - used only if the native file-watching mechanism from 'listen' is not
      #   being used. The default value is 1 second.
      # @option options [Boolean] :force_polling  Force polling even if the 'listen' gem is available.
      #   The default value is false.
      # @return [Proc] a builder proc that can be used as an FDv2 initializer or synchronizer
      #
      # @example Using as an initializer
      #   file_source = LaunchDarkly::Integrations::FileData.data_source_v2(paths: ['flags.json'])
      #   data_system_config = LaunchDarkly::DataSystemConfig.new(
      #     initializers: [file_source]
      #   )
      #   config = LaunchDarkly::Config.new(data_system: data_system_config)
      #
      # @example Using as a synchronizer
      #   file_source = LaunchDarkly::Integrations::FileData.data_source_v2(paths: ['flags.json'])
      #   data_system_config = LaunchDarkly::DataSystemConfig.new(
      #     synchronizer: file_source
      #   )
      #   config = LaunchDarkly::Config.new(data_system: data_system_config)
      #
      # @example Using as both initializer and synchronizer
      #   file_source = LaunchDarkly::Integrations::FileData.data_source_v2(paths: ['flags.json'])
      #   data_system_config = LaunchDarkly::DataSystemConfig.new(
      #     initializers: [file_source],
      #     synchronizer: file_source
      #   )
      #   config = LaunchDarkly::Config.new(data_system: data_system_config)
      #
      def self.data_source_v2(options = {})
        paths = options[:paths] || []
        poll_interval = options[:poll_interval] || 1
        force_polling = options[:force_polling] || false

        lambda { |_sdk_key, config|
          Impl::Integrations::FileDataSourceV2.new(
            config.logger,
            paths: paths,
            poll_interval: poll_interval,
            force_polling: force_polling
          )
        }
      end
    end
  end
end
