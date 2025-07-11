module LaunchDarkly
  module Interfaces
    module Plugins
      #
      # Metadata about the SDK.
      #
      class SdkMetadata
        # The id of the SDK (e.g., "ruby-server-sdk")
        # @return [String]
        attr_reader :name
        
        # The version of the SDK
        # @return [String]
        attr_reader :version
        
        # The wrapper name if this SDK is a wrapper
        # @return [String, nil]
        attr_reader :wrapper_name
        
        # The wrapper version if this SDK is a wrapper
        # @return [String, nil]
        attr_reader :wrapper_version

        def initialize(name:, version:, wrapper_name: nil, wrapper_version: nil)
          @name = name
          @version = version
          @wrapper_name = wrapper_name
          @wrapper_version = wrapper_version
        end
      end

      #
      # Metadata about the application using the SDK.
      #
      class ApplicationMetadata
        # The id of the application
        # @return [String, nil]
        attr_reader :id
        
        # The version of the application
        # @return [String, nil]
        attr_reader :version

        def initialize(id: nil, version: nil)
          @id = id
          @version = version
        end
      end

      #
      # Metadata about the environment in which the SDK is running.
      #
      class EnvironmentMetadata
        # Information about the SDK
        # @return [SdkMetadata]
        attr_reader :sdk
        
        # Information about the application
        # @return [ApplicationMetadata, nil]
        attr_reader :application
        
        # The SDK key used to initialize the SDK
        # @return [String, nil]
        attr_reader :sdk_key

        def initialize(sdk:, application: nil, sdk_key: nil)
          @sdk = sdk
          @application = application
          @sdk_key = sdk_key
        end
      end

      #
      # Metadata about a plugin implementation.
      #
      class PluginMetadata
        # A name representing the plugin instance
        # @return [String]
        attr_reader :name

        def initialize(name)
          @name = name
        end
      end

      #
      # Mixin for extending SDK functionality via plugins.
      #
      # All provided plugin implementations **MUST** include this mixin. Plugins without this mixin will be ignored.
      #
      # This mixin includes default implementations for optional methods. This allows LaunchDarkly to expand the list
      # of plugin methods without breaking customer integrations.
      #
      # Plugins provide an interface which allows for initialization, access to credentials, and hook registration
      # in a single interface.
      #
      module Plugin
        #
        # Get metadata about the plugin implementation.
        #
        # @return [PluginMetadata]
        #
        def metadata
          PluginMetadata.new('UNDEFINED')
        end

        #
        # Register the plugin with the SDK client.
        #
        # This method is called during SDK initialization to allow the plugin to set up any necessary integrations,
        # register hooks, or perform other initialization tasks.
        #
        # @param client [LDClient] The LDClient instance
        # @param environment_metadata [EnvironmentMetadata] Metadata about the environment in which the SDK is running
        # @return [void]
        #
        def register(client, environment_metadata)
          # Default implementation does nothing
        end

        #
        # Get a list of hooks that this plugin provides.
        #
        # This method is called before register() to collect all hooks from plugins. The hooks returned will be
        # added to the SDK's hook configuration.
        #
        # @param environment_metadata [EnvironmentMetadata] Metadata about the environment in which the SDK is running
        # @return [Array<Interfaces::Hooks::Hook>] A list of hooks to be registered with the SDK
        #
        def get_hooks(environment_metadata)
          []
        end
      end
    end
  end
end 