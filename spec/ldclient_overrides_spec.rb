require "spec_helper"
require "capturing_logger"
require "model_builders"
require "override_test_components"
require "ldclient-rb/integrations/test_data_v2"

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

    # A store that holds the given LaunchDarkly flags but no init marker, like a persistent store
    # that LaunchDarkly data was written to before an interrupted initialization.
    def store_without_init_marker(*flags)
      store = InMemoryFeatureStore.new
      flags.each { |f| store.upsert(Impl::DataStore::FEATURES, Impl::Model.deserialize(Impl::DataStore::FEATURES, f)) }
      expect(store.initialized?).to be false
      store
    end

    # A client with a data source that never delivers data, reading LaunchDarkly data from the given
    # store.
    def uninitialized_data_system_with_store(store, overrides: nil)
      builder = DataSystem.custom.synchronizers([HangingSynchronizer.new]).data_store(store, :read_write)
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

      it "keeps the marking when evaluating an overridden flag raises" do
        source = TestOverrideSource.new([override_flag])
        with_client(data_system(overrides: source, flags: { flag: ld_flag, normal: ld_normal })) do |client|
          allow(client.instance_variable_get(:@evaluator)).to receive(:evaluate).and_raise("evaluation failed")

          detail = client.variation_detail("flag", context, "default")
          expect(detail.value).to eq "default"
          expect(detail.reason).to eq EvaluationReason.error(EvaluationReason::ERROR_EXCEPTION).with_override_affected(true)

          normal = client.variation_detail("normal", context, "default")
          expect(normal.reason).to eq EvaluationReason.error(EvaluationReason::ERROR_EXCEPTION)
        end
      end

      it "returns the EXCEPTION result for a flag that a custom store returns as a plain hash" do
        # The FeatureStore interface documents its entities as hashes, while the SDK's own stores
        # return model objects. The evaluator raises on a plain hash, and that failure must still give
        # the EXCEPTION result, with or without an override source, as it did before overrides.
        flag_hash = { key: "plain", version: 1, on: false, offVariation: 0, variations: ["value"] }
        store = InMemoryFeatureStore.new
        store.define_singleton_method(:initialized?) { true }
        store.define_singleton_method(:get) { |kind, key| kind == Impl::DataStore::FEATURES && key == "plain" ? flag_hash : nil }
        store.define_singleton_method(:all) { |kind| kind == Impl::DataStore::FEATURES ? { plain: flag_hash } : {} }
        [nil, TestOverrideSource.new([override_flag.merge(key: "other")])].each do |source|
          builder = DataSystem.custom.data_store(store, :read_only)
          builder.overrides(source) if source
          with_client(builder.build) do |client|
            detail = client.variation_detail("plain", context, "default")
            expect(detail.value).to eq "default"
            expect(detail.reason).to eq EvaluationReason.error(EvaluationReason::ERROR_EXCEPTION)

            meta = client.all_flags_state(context, with_reasons: true).as_json["$flagsState"]
            expect(meta["plain"][:reason]).to eq EvaluationReason.error(EvaluationReason::ERROR_EXCEPTION)
          end
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

      it "does not serve LaunchDarkly data from a store without an init marker for a flag that is not overridden" do
        # Configuring a source changes nothing for a flag that it does not override: the result is
        # the not-ready default, as it is without a source.
        [nil, TestOverrideSource.new([override_flag.merge(key: "other")])].each do |source|
          store = store_without_init_marker(ld_flag)
          with_client(uninitialized_data_system_with_store(store, overrides: source)) do |client|
            detail = client.variation_detail("flag", context, "default")

            expect(detail.value).to eq "default"
            expect(detail.reason).to eq EvaluationReason.error(EvaluationReason::ERROR_CLIENT_NOT_READY)
          end
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

      it "returns an invalid state before initialization when the override store is empty and the store holds LaunchDarkly data without an init marker" do
        [nil, TestOverrideSource.new([])].each do |source|
          with_client(uninitialized_data_system_with_store(store_without_init_marker(ld_flag), overrides: source)) do |client|
            state = client.all_flags_state(context)

            expect(state.valid?).to be false
            expect(state.values_map).to eq({})
          end
        end
      end

      it "returns only the overridden flags before initialization when the store holds LaunchDarkly data without an init marker" do
        source = TestOverrideSource.new([override_flag.merge(key: "other")])
        with_client(uninitialized_data_system_with_store(store_without_init_marker(ld_flag), overrides: source)) do |client|
          state = client.all_flags_state(context)

          expect(state.valid?).to be true
          expect(state.values_map).to eq({ "other" => "override-value" })
        end
      end

      it "returns an invalid state of the overridden flags and logs the failure when the store cannot list its flags" do
        # A daemon-mode client reads its store directly. Overrides only add to the state: without
        # them it is invalid and empty, so with them it holds the overridden flags and stays invalid.
        store = InMemoryFeatureStore.new
        store.define_singleton_method(:all) { |_kind| raise "store failed" }
        source = TestOverrideSource.new([override_flag])
        logger = CapturingLogger.new
        with_client(DataSystem.custom.data_store(store, :read_only).overrides(source).build, logger: logger) do |client|
          expect(client.initialized?).to be true
          state = client.all_flags_state(context, with_reasons: true)

          expect(state.valid?).to be false
          expect(state.values_map).to eq({ "flag" => "override-value" })
          json = state.as_json
          expect(json["$valid"]).to be false
          expect(json["flag"]).to eq "override-value"
          expect(json["$flagsState"]["flag"][:reason]).to eq EvaluationReason.off.with_override_affected(true)
          expect(logger.output).to include("Unable to read flags for all_flags_state")
          expect(logger.output).to include("store failed")
        end
      end

      it "returns an invalid, empty state and logs the failure when the store cannot list its flags and no flags are overridden" do
        store = InMemoryFeatureStore.new
        store.define_singleton_method(:all) { |_kind| raise "store failed" }
        [nil, TestOverrideSource.new([])].each do |source|
          logger = CapturingLogger.new
          with_client(DataSystem.custom.data_store(store, :read_only).overrides(source).build, logger: logger) do |client|
            state = client.all_flags_state(context)

            expect(state.valid?).to be false
            expect(state.values_map).to eq({})
            expect(logger.output).to include("Unable to read flags for all_flags_state")
          end
        end
      end

      it "reports a flag whose evaluation raises with an error reason that keeps the marking" do
        source = TestOverrideSource.new([override_flag])
        with_client(data_system(overrides: source, flags: { flag: ld_flag, normal: ld_normal })) do |client|
          allow(client.instance_variable_get(:@evaluator)).to receive(:evaluate).and_raise("evaluation failed")

          state = client.all_flags_state(context, with_reasons: true)

          expect(state.valid?).to be true
          expect(state.values_map).to eq({ "flag" => nil, "normal" => nil })
          json = state.as_json
          expect(json["$flagsState"]["flag"][:reason]).to eq(
            EvaluationReason.error(EvaluationReason::ERROR_EXCEPTION).with_override_affected(true))
          expect(json["$flagsState"]["normal"][:reason]).to eq EvaluationReason.error(EvaluationReason::ERROR_EXCEPTION)
        end
      end

      it "reports no prerequisites for a flag whose evaluation raises after a flag with prerequisites" do
        # Each invocation of the block gets its own local variables, so a failed flag cannot pick up
        # the evaluation state of the flag evaluated before it.
        prereq = { key: "prereq", version: 1, on: false, offVariation: 0, variations: ["p"] }
        holder = { key: "holder", version: 1, on: true, fallthrough: { variation: 0 }, variations: ["h"],
                   prerequisites: [{ key: "prereq", variation: 0 }] }
        failing = { key: "failing", version: 1, on: false, offVariation: 0, variations: ["f"] }
        with_client(data_system(flags: { prereq: prereq, holder: holder, failing: failing })) do |client|
          order = []
          allow(client.instance_variable_get(:@evaluator)).to receive(:evaluate).and_wrap_original do |original, flag, ctx|
            order << flag[:key]
            raise "evaluation failed" if flag[:key] == "failing"
            original.call(flag, ctx)
          end

          meta = client.all_flags_state(context, with_reasons: true).as_json["$flagsState"]

          # The flag evaluated just before the failing one has a prerequisite.
          expect(order[order.index("failing") - 1]).to eq "holder"
          expect(meta["holder"][:prerequisites]).to eq ["prereq"]
          expect(meta["failing"]).not_to have_key(:prerequisites)
          expect(meta["failing"][:reason]).to eq EvaluationReason.error(EvaluationReason::ERROR_EXCEPTION)
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

      it "fires for an override flag when the LaunchDarkly prerequisite it depends on changes" do
        td = Integrations::TestDataV2.data_source
        td.update(td.flag("prereq").on(true))
        override_dependent = { key: "override-dependent", version: 1, on: true, prerequisites: [{ key: "prereq", variation: 0 }],
                               fallthrough: { variation: 0 }, offVariation: 0, variations: ["d"] }
        source = TestOverrideSource.new([override_dependent])
        config = DataSystem.custom.synchronizers([td.test_data_ds_builder]).overrides(source).build
        with_client(config, wait: 5) do |client|
          expect(client.initialized?).to be true
          listener = CollectingFlagChangeListener.new
          client.flag_tracker.add_listener(listener)

          td.update(td.flag("prereq").on(false))

          expect(listener.collect).to eq %w[override-dependent prereq]
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

          change = TestQueues.pop_within(changes, 2)
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

      it "has no effect when the client is offline, and logs that" do
        source = TestOverrideSource.new([override_flag])
        logger = CapturingLogger.new
        config = Config.new(data_system_config: data_system(overrides: source), offline: true, logger: logger)
        client = LDClient.new("sdk-key", config, 0)
        begin
          expect(source.started?).to be false
          expect(client.variation("flag", context, "default")).to eq "default"
          expect(logger.output).to include("Offline mode is enabled; the override source is not started and no overrides are served")
        ensure
          client.close
        end
      end

      it "starts and runs without overrides when the source raises from start" do
        # The SDK's own source never raises from start. A custom source could, and that must not
        # keep the client from starting. The snapshot it supplied before failing is removed.
        source = TestOverrideSource.new([override_flag])
        source.define_singleton_method(:start) do |sink|
          sink.set_overrides([{ key: "flag", version: 1, on: false, offVariation: 0, variations: ["override-value"] }], [])
          raise "source failed"
        end
        logger = CapturingLogger.new
        with_client(data_system(overrides: source, flags: { flag: ld_flag }), logger: logger) do |client|
          expect(source.stopped?).to be true
          expect(logger.output).to include("Unable to start the override source; the client runs without overrides")

          detail = client.variation_detail("flag", context, "default")
          expect(detail.value).to eq "ld-value"
          expect(detail.reason.override_affected).to be false
        end
      end
    end
  end
end
