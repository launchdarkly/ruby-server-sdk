require "mock_components"
require "spec_helper"

module LaunchDarkly
  describe "LDClient plugins tests" do
    context "plugin configuration" do
      it "can register a plugin on the config" do
        plugin = MockPlugin.new("test-plugin")
        config = test_config(plugins: [plugin])
        expect(config.plugins.length).to eq 1
        expect(config.plugins[0]).to eq plugin
      end

      it "will drop invalid plugins on config" do
        config = test_config(plugins: [true, nil, "example thing"])
        expect(config.plugins.count).to eq 0
      end

      it "can register multiple plugins" do
        plugin1 = MockPlugin.new("plugin1")
        plugin2 = MockPlugin.new("plugin2")
        config = test_config(plugins: [plugin1, plugin2])
        expect(config.plugins.length).to eq 2
      end
    end

    context "plugin hook collection" do
      it "collects hooks from plugins" do
        hook = MockHook.new(->(_, _) { }, ->(_, _, _) { })
        plugin = MockPlugin.new("test-plugin", [hook])

        with_client(test_config(plugins: [plugin])) do |client|
          expect(client.instance_variable_get("@hooks")).to include(hook)
        end
      end

      it "handles plugin hook errors gracefully" do
        plugin = MockPlugin.new("error-plugin")
        allow(plugin).to receive(:get_hooks).and_raise("Hook error")

        with_client(test_config(plugins: [plugin])) do |client|
          expect(client).to be_initialized
        end
      end
    end

    context "plugin registration" do
      it "calls register on plugins during initialization" do
        registered = false
        register_callback = ->(client, metadata) { registered = true }
        plugin = MockPlugin.new("test-plugin", [], register_callback)

        with_client(test_config(plugins: [plugin])) do |client|
          expect(registered).to be true
        end
      end

      it "provides correct environment metadata to plugins" do
        received_metadata = nil
        register_callback = ->(client, metadata) { received_metadata = metadata }
        plugin = MockPlugin.new("test-plugin", [], register_callback)

        with_client(test_config(plugins: [plugin])) do |client|
          expect(received_metadata).to be_a(Interfaces::Plugins::EnvironmentMetadata)
          expect(received_metadata.sdk.name).to eq("ruby-server-sdk")
          expect(received_metadata.sdk.version).to eq(LaunchDarkly::VERSION)
        end
      end

      it "handles plugin registration errors gracefully" do
        register_callback = ->(client, metadata) { raise "Registration error" }
        plugin = MockPlugin.new("error-plugin", [], register_callback)

        with_client(test_config(plugins: [plugin])) do |client|
          expect(client).to be_initialized
        end
      end
    end

    context "plugin execution order" do
      it "registers plugins in the order they were added" do
        order = []
        plugin1 = MockPlugin.new("plugin1", [], ->(_, _) { order << "plugin1" })
        plugin2 = MockPlugin.new("plugin2", [], ->(_, _) { order << "plugin2" })

        with_client(test_config(plugins: [plugin1, plugin2])) do |client|
          expect(order).to eq ["plugin1", "plugin2"]
        end
      end

      it "plugin hooks are added after config hooks" do
        config_hook = MockHook.new(->(_, _) { }, ->(_, _, _) { })
        plugin_hook = MockHook.new(->(_, _) { }, ->(_, _, _) { })
        plugin = MockPlugin.new("test-plugin", [plugin_hook])

        with_client(test_config(hooks: [config_hook], plugins: [plugin])) do |client|
          hooks = client.instance_variable_get("@hooks")
          config_hook_index = hooks.index(config_hook)
          plugin_hook_index = hooks.index(plugin_hook)
          expect(config_hook_index).to be < plugin_hook_index
        end
      end
    end

    context "metadata classes" do
      it "creates SdkMetadata correctly" do
        metadata = Interfaces::Plugins::SdkMetadata.new(
          name: "test-sdk",
          version: "1.0.0",
          wrapper_name: "test-wrapper",
          wrapper_version: "2.0.0"
        )

        expect(metadata.name).to eq("test-sdk")
        expect(metadata.version).to eq("1.0.0")
        expect(metadata.wrapper_name).to eq("test-wrapper")
        expect(metadata.wrapper_version).to eq("2.0.0")
      end

      it "creates ApplicationMetadata correctly" do
        metadata = Interfaces::Plugins::ApplicationMetadata.new(
          id: "test-app",
          version: "3.0.0"
        )

        expect(metadata.id).to eq("test-app")
        expect(metadata.version).to eq("3.0.0")
      end

      it "creates EnvironmentMetadata correctly" do
        sdk_metadata = Interfaces::Plugins::SdkMetadata.new(name: "test", version: "1.0")
        app_metadata = Interfaces::Plugins::ApplicationMetadata.new(id: "app")

        metadata = Interfaces::Plugins::EnvironmentMetadata.new(
          sdk: sdk_metadata,
          application: app_metadata,
          sdk_key: "test-key"
        )

        expect(metadata.sdk).to eq(sdk_metadata)
        expect(metadata.application).to eq(app_metadata)
        expect(metadata.sdk_key).to eq("test-key")
      end
    end
  end
end
