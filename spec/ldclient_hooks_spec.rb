require "ldclient-rb"

require "mock_components"
require "model_builders"
require "spec_helper"

module LaunchDarkly
  describe "LDClient hooks tests" do
    context "registration" do
      it "can register a hook on the config" do
        count = 0
        hook = MockHook.new(->(_, _) { count += 1 }, ->(_, _, _) { count += 2 })
        with_client(test_config(hooks: [hook])) do |client|
          client.variation("doesntmatter", basic_context, "default")
          expect(count).to eq 3
        end
      end

      it "can register a hook on the client" do
        count = 0
        hook = MockHook.new(->(_, _) { count += 1 }, ->(_, _, _) { count += 2 })
        with_client(test_config()) do |client|
          client.add_hook(hook)
          client.variation("doesntmatter", basic_context, "default")

          expect(count).to eq 3
        end
      end

      it "can register hooks on both" do
        count = 0
        config_hook = MockHook.new(->(_, _) { count += 1 }, ->(_, _, _) { count += 2 })
        client_hook = MockHook.new(->(_, _) { count += 4 }, ->(_, _, _) { count += 8 })

        with_client(test_config(hooks: [config_hook])) do |client|
          client.add_hook(client_hook)
          client.variation("doesntmatter", basic_context, "default")

          expect(count).to eq 15
        end
      end

      it "will drop invalid hooks on config" do
        config = test_config(hooks: [true, nil, "example thing"])
        expect(config.hooks.count).to eq 0
      end

      it "will drop invalid hooks on client" do
        with_client(test_config) do |client|
          client.add_hook(true)
          client.add_hook(nil)
          client.add_hook("example thing")

          expect(client.instance_variable_get("@hooks").count).to eq 0
        end

        config = test_config(hooks: [true, nil, "example thing"])
        expect(config.hooks.count).to eq 0
      end
    end

    context "execution order" do
      it "config order is preserved" do
        order = []
        first_hook = MockHook.new(->(_, _) { order << "first before" }, ->(_, _, _) { order << "first after" })
        second_hook = MockHook.new(->(_, _) { order << "second before" }, ->(_, _, _) { order << "second after" })

        with_client(test_config(hooks: [first_hook, second_hook])) do |client|
          client.variation("doesntmatter", basic_context, "default")
          expect(order).to eq ["first before", "second before", "second after", "first after"]
        end
      end

      it "client order is preserved" do
        order = []
        first_hook = MockHook.new(->(_, _) { order << "first before" }, ->(_, _, _) { order << "first after" })
        second_hook = MockHook.new(->(_, _) { order << "second before" }, ->(_, _, _) { order << "second after" })

        with_client(test_config()) do |client|
          client.add_hook(first_hook)
          client.add_hook(second_hook)
          client.variation("doesntmatter", basic_context, "default")

          expect(order).to eq ["first before", "second before", "second after", "first after"]
        end
      end

      it "config hooks precede client hooks" do
        order = []
        config_hook = MockHook.new(->(_, _) { order << "config before" }, ->(_, _, _) { order << "config after" })
        client_hook = MockHook.new(->(_, _) { order << "client before" }, ->(_, _, _) { order << "client after" })

        with_client(test_config(hooks: [config_hook])) do |client|
          client.add_hook(client_hook)
          client.variation("doesntmatter", basic_context, "default")

          expect(order).to eq ["config before", "client before", "client after", "config after"]
        end
      end
    end

    context "passing data" do
      it "hook receives EvaluationDetail" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("value").variation_for_all(0))

        detail = nil
        config_hook = MockHook.new(->(_, _) { }, ->(_, _, d) { detail = d })
        with_client(test_config(data_source: td, hooks: [config_hook])) do |client|
          client.variation("flagkey", basic_context, "default")

          expect(detail.value).to eq "value"
          expect(detail.variation_index).to eq 0
          expect(detail.reason).to eq EvaluationReason::fallthrough
        end
      end

      it "from before evaluation to after evaluation" do
        actual = nil
        config_hook = MockHook.new(->(_, _) { "example string returned" }, ->(_, hook_data, _) { actual = hook_data })
        with_client(test_config(hooks: [config_hook])) do |client|
          client.variation("doesntmatter", basic_context, "default")

          expect(actual).to eq "example string returned"
        end
      end

      it "exception receives nil value" do
        actual = nil
        config_hook = MockHook.new(->(_, _) { raise "example string returned" }, ->(_, hook_data, _) { actual = hook_data })
        with_client(test_config(hooks: [config_hook])) do |client|
          client.variation("doesntmatter", basic_context, "default")

          expect(actual).to be_nil
        end
      end

      it "exceptions do not mess up data passing order" do
        data = []
        first_hook = MockHook.new(->(_, _) { "first hook" }, ->(_, hook_data, _) { data << hook_data })
        second_hook = MockHook.new(->(_, _) { raise "second hook" }, ->(_, hook_data, _) { data << hook_data })
        third_hook = MockHook.new(->(_, _) { "third hook" }, ->(_, hook_data, _) { data << hook_data })
        with_client(test_config(hooks: [first_hook, second_hook, third_hook])) do |client|
          client.variation("doesntmatter", basic_context, "default")

          # NOTE: These are reversed since the push happens in the after_evaluation (when hooks are reversed)
          expect(data).to eq ["third hook", nil, "first hook"]
        end
      end
    end

    context "migration variation" do
      it "EvaluationDetail contains stage value" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("off").variation_for_all(0))

        detail = nil
        config_hook = MockHook.new(->(_, _) { }, ->(_, _, d) { detail = d })
        with_client(test_config(data_source: td, hooks: [config_hook])) do |client|
          client.migration_variation("flagkey", basic_context, LaunchDarkly::Migrations::STAGE_LIVE)

          expect(detail.value).to eq LaunchDarkly::Migrations::STAGE_OFF.to_s
          expect(detail.variation_index).to eq 0
          expect(detail.reason).to eq EvaluationReason::fallthrough
        end
      end

      it "EvaluationDetail gets default if flag doesn't evaluate to stage" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("nonstage").variation_for_all(0))

        detail = nil
        config_hook = MockHook.new(->(_, _) { }, ->(_, _, d) { detail = d })
        with_client(test_config(data_source: td, hooks: [config_hook])) do |client|
          client.migration_variation("flagkey", basic_context, LaunchDarkly::Migrations::STAGE_LIVE)

          expect(detail.value).to eq LaunchDarkly::Migrations::STAGE_LIVE.to_s
          expect(detail.variation_index).to eq nil
          expect(detail.reason).to eq EvaluationReason.error(EvaluationReason::ERROR_WRONG_TYPE)
        end
      end

      it "EvaluationDetail default gets converted to off if invalid" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("nonstage").variation_for_all(0))

        detail = nil
        config_hook = MockHook.new(->(_, _) { }, ->(_, _, d) { detail = d })
        with_client(test_config(data_source: td, hooks: [config_hook])) do |client|
          client.migration_variation("flagkey", basic_context, :invalid)

          expect(detail.value).to eq LaunchDarkly::Migrations::STAGE_OFF.to_s
          expect(detail.variation_index).to eq nil
          expect(detail.reason).to eq EvaluationReason.error(EvaluationReason::ERROR_WRONG_TYPE)
        end
      end
    end
  end
end
