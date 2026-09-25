require "spec_helper"
require "capturing_logger"
require "model_builders"
require "override_test_components"

module LaunchDarkly
  describe LDClient, "with flag overrides" do
    let(:context) { LDContext.create({ key: "user-key", kind: "user" }) }
    let(:ld_flag) { { key: "flag", version: 100, on: false, offVariation: 0, variations: ["ld-value"] } }
    let(:ld_normal) { { key: "normal", version: 100, on: false, offVariation: 0, variations: ["normal-value"] } }
    let(:override_flag) { { key: "flag", version: 1, on: false, offVariation: 0, variations: ["override-value"] } }

    def data_system(overrides: nil, initialized: true, flags: {}, segments: {})
      builder = DataSystem.custom
      if initialized
        builder.initializers([TestDataInitializer.new(flags: flags, segments: segments)])
      else
        builder.synchronizers([HangingSynchronizer.new])
      end
      builder.overrides(overrides) if overrides
      builder.build
    end

    def with_client(data_system_config, wait: nil, logger: $null_log)
      config = Config.new(data_system_config: data_system_config, send_events: false, logger: logger)
      wait = data_system_config.synchronizers.nil? ? 5 : 0 if wait.nil?
      client = LDClient.new("sdk-key", config, wait)
      begin
        yield client
      ensure
        client.close
      end
    end

    describe "configuration" do
      it "accepts an override source on the data system builder" do
        source = TestOverrideSource.new
        config = DataSystem.default.overrides(source).build

        expect(config.overrides).to be source
      end

      it "leaves the override source unset by default and allows it to be removed" do
        expect(DataSystem.default.build.overrides).to be_nil
        expect(DataSystem.custom.overrides(TestOverrideSource.new).overrides(nil).build.overrides).to be_nil
      end

      it "reports an override source that cannot be built as a construction error" do
        builder = Object.new
        builder.define_singleton_method(:build) { |_sdk_key, _config| raise ArgumentError, "no file paths" }
        config = Config.new(data_system_config: data_system(overrides: builder), send_events: false, logger: $null_log)

        expect { LDClient.new("sdk-key", config, 0) }.to raise_error(ArgumentError, "no file paths")
      end
    end

    describe "evaluation when the client is initialized" do
      it "serves the override entry in preference to LaunchDarkly data and marks the reason" do
        source = TestOverrideSource.new([override_flag])
        with_client(data_system(overrides: source, flags: { flag: ld_flag, normal: ld_normal })) do |client|
          expect(client.initialized?).to be true

          detail = client.variation_detail("flag", context, "default")
          expect(detail.value).to eq "override-value"
          expect(detail.variation_index).to eq 0
          expect(detail.reason).to eq EvaluationReason.off.with_override_affected(true)
          expect(client.variation("flag", context, "default")).to eq "override-value"
        end
      end

      it "leaves a flag without an override unaffected" do
        source = TestOverrideSource.new([override_flag])
        with_client(data_system(overrides: source, flags: { flag: ld_flag, normal: ld_normal })) do |client|
          detail = client.variation_detail("normal", context, "default")

          expect(detail.value).to eq "normal-value"
          expect(detail.reason).to eq EvaluationReason.off
          expect(detail.reason.override_affected).to be false
        end
      end

      it "behaves as without the feature when the source supplies no overrides" do
        source = TestOverrideSource.new([])
        with_client(data_system(overrides: source, flags: { flag: ld_flag })) do |client|
          detail = client.variation_detail("flag", context, "default")

          expect(detail.value).to eq "ld-value"
          expect(detail.reason.override_affected).to be false
          expect(client.variation("unknown", context, "default")).to eq "default"
        end
      end

      it "returns to LaunchDarkly data when the override is removed, and to the default when there is none" do
        source = TestOverrideSource.new([override_flag, override_flag.merge(key: "only-override")])
        with_client(data_system(overrides: source, flags: { flag: ld_flag })) do |client|
          expect(client.variation("only-override", context, "default")).to eq "override-value"

          source.update([])

          expect(client.variation("flag", context, "default")).to eq "ld-value"
          detail = client.variation_detail("only-override", context, "default")
          expect(detail.value).to eq "default"
          expect(detail.reason).to eq EvaluationReason.error(EvaluationReason::ERROR_FLAG_NOT_FOUND)
        end
      end

      it "keeps the marking when a migration stage is not a valid stage" do
        source = TestOverrideSource.new([override_flag.merge(variations: ["not-a-stage"])])
        with_client(data_system(overrides: source, flags: { flag: ld_flag })) do |client|
          stage, tracker = client.migration_variation("flag", context, Migrations::STAGE_OFF)

          expect(stage).to eq Migrations::STAGE_OFF
          detail = tracker.instance_variable_get(:@detail)
          expect(detail.reason.error_kind).to eq EvaluationReason::ERROR_WRONG_TYPE
          expect(detail.reason.override_affected).to be true
        end
      end
    end

    describe "evaluation before the client is initialized" do
      it "serves an overridden flag" do
        source = TestOverrideSource.new([override_flag])
        with_client(data_system(overrides: source, initialized: false)) do |client|
          expect(client.initialized?).to be false

          detail = client.variation_detail("flag", context, "default")
          expect(detail.value).to eq "override-value"
          expect(detail.reason).to eq EvaluationReason.off.with_override_affected(true)
        end
      end

      it "returns the default with a client-not-ready reason for a flag that is not overridden" do
        source = TestOverrideSource.new([override_flag])
        logger = CapturingLogger.new
        with_client(data_system(overrides: source, initialized: false), logger: logger) do |client|
          detail = client.variation_detail("other", context, "default")

          expect(detail.value).to eq "default"
          expect(detail.variation_index).to be_nil
          expect(detail.reason).to eq EvaluationReason.error(EvaluationReason::ERROR_CLIENT_NOT_READY)
          expect(logger.output).to include("Client has not finished initializing")
        end
      end

      it "still short-circuits when no override source is configured" do
        with_client(data_system(initialized: false)) do |client|
          detail = client.variation_detail("flag", context, "default")

          expect(detail.reason).to eq EvaluationReason.error(EvaluationReason::ERROR_CLIENT_NOT_READY)
        end
      end

      it "does not report the client as initialized because of overrides" do
        source = TestOverrideSource.new([override_flag])
        with_client(data_system(overrides: source, initialized: false)) do |client|
          expect(client.initialized?).to be false
          expect(client.data_source_status_provider.status.state).not_to eq Interfaces::DataSource::Status::VALID
        end
      end
    end

    describe "all_flags_state" do
      it "reflects overrides and includes flags that exist only in the override store" do
        source = TestOverrideSource.new([override_flag, override_flag.merge(key: "only-override", variations: ["extra"])])
        with_client(data_system(overrides: source, flags: { flag: ld_flag, normal: ld_normal })) do |client|
          state = client.all_flags_state(context, with_reasons: true)

          expect(state.valid?).to be true
          expect(state.values_map).to eq({ "flag" => "override-value", "normal" => "normal-value", "only-override" => "extra" })
          json = state.as_json
          expect(json["$flagsState"]["flag"][:reason]).to eq EvaluationReason.off.with_override_affected(true)
          expect(json["$flagsState"]["normal"][:reason]).to eq EvaluationReason.off
        end
      end

      it "returns only the overridden flags before initialization and logs that once" do
        source = TestOverrideSource.new([override_flag])
        logger = CapturingLogger.new
        with_client(data_system(overrides: source, initialized: false), logger: logger) do |client|
          state = client.all_flags_state(context)
          client.all_flags_state(context)

          expect(state.valid?).to be true
          expect(state.values_map).to eq({ "flag" => "override-value" })
          expect(logger.output.scan("returning only flags from the override store").length).to eq 1
        end
      end

      it "returns an invalid state before initialization when the override store is empty" do
        source = TestOverrideSource.new([])
        with_client(data_system(overrides: source, initialized: false)) do |client|
          state = client.all_flags_state(context)

          expect(state.valid?).to be false
        end
      end

      it "returns an invalid state before initialization when no override source is configured" do
        with_client(data_system(initialized: false)) do |client|
          expect(client.all_flags_state(context).valid?).to be false
        end
      end
    end

    describe "flag change notifications" do
      let(:prereq_ld) { { key: "prereq", version: 100, on: true, fallthrough: { variation: 0 }, offVariation: 0, variations: ["p"] } }
      let(:dependent_ld) do
        { key: "dependent", version: 100, on: true, prerequisites: [{ key: "prereq", variation: 0 }],
          fallthrough: { variation: 0 }, offVariation: 0, variations: ["d"] }
      end

      it "fires when an override is added, changed, and removed" do
        source = TestOverrideSource.new([])
        with_client(data_system(overrides: source, flags: { flag: ld_flag })) do |client|
          listener = CollectingFlagChangeListener.new
          client.flag_tracker.add_listener(listener)

          source.update([override_flag])
          expect(listener.collect).to eq %w[flag]

          source.update([override_flag.merge(variations: ["changed"])])
          expect(listener.collect).to eq %w[flag]

          source.update([])
          expect(listener.collect).to eq %w[flag]
        end
      end

      it "fires for flags that depend on an overridden prerequisite" do
        source = TestOverrideSource.new([])
        with_client(data_system(overrides: source, flags: { prereq: prereq_ld, dependent: dependent_ld, flag: ld_flag })) do |client|
          listener = CollectingFlagChangeListener.new
          client.flag_tracker.add_listener(listener)

          source.update([prereq_ld.merge(version: 200, variations: ["p2"])])

          expect(listener.collect).to eq %w[dependent prereq]
        end
      end

      it "reports the new value to a flag value change listener" do
        source = TestOverrideSource.new([])
        with_client(data_system(overrides: source, flags: { flag: ld_flag })) do |client|
          changes = Queue.new
          listener = Object.new
          listener.define_singleton_method(:update) { |change| changes << change }
          client.flag_tracker.add_flag_value_change_listener("flag", context, listener)

          source.update([override_flag])

          change = changes.pop(timeout: 2)
          expect(change).not_to be_nil
          expect(change.old_value).to eq "ld-value"
          expect(change.new_value).to eq "override-value"
        end
      end
    end

    describe "lifecycle" do
      it "starts the source during construction and stops it when the client closes" do
        source = TestOverrideSource.new([override_flag])
        config = Config.new(data_system_config: data_system(overrides: source, flags: { flag: ld_flag }), send_events: false, logger: $null_log)
        client = LDClient.new("sdk-key", config, 5)

        expect(source.started?).to be true
        client.close
        expect(source.stopped?).to be true
      end

      it "has no effect when the client is offline" do
        source = TestOverrideSource.new([override_flag])
        config = Config.new(data_system_config: data_system(overrides: source), offline: true, logger: $null_log)
        client = LDClient.new("sdk-key", config, 0)
        begin
          expect(source.started?).to be false
          expect(client.variation("flag", context, "default")).to eq "default"
        ensure
          client.close
        end
      end
    end
  end
end
