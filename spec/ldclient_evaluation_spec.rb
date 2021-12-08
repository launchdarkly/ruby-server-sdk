require "ldclient-rb"

require "mock_components"
require "model_builders"
require "spec_helper"

module LaunchDarkly
  describe "LDClient evaluation tests" do
    context "variation" do
      it "returns the default value if the client is offline" do
        with_client(test_config(offline: true)) do |offline_client|
          result = offline_client.variation("doesntmatter", basic_user, "default")
          expect(result).to eq "default"
        end
      end

      it "returns the default value for an unknown feature" do
        with_client(test_config) do |client|
          expect(client.variation("badkey", basic_user, "default")).to eq "default"
        end
      end

      it "returns the value for an existing feature" do
        flag = FlagBuilder.new("flagkey").off_with_value("value").build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)
        
        with_client(test_config(feature_store: store)) do |client|
          expect(client.variation("flagkey", basic_user, "default")).to eq "value"
        end
      end

      it "returns the default value if a feature evaluates to nil" do
        flag = FlagBuilder.new("flagkey").on(false).off_variation(nil).build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)
        
        with_client(test_config(feature_store: store)) do |client|
          expect(client.variation("flagkey", basic_user, "default")).to eq "default"
        end
      end

      it "can evaluate a flag that references a segment" do
        segment = SegmentBuilder.new("segmentkey").included(basic_user[:key]).build
        flag = FlagBuilder.new("flagkey").on(true).variations(true, false).rule(
          RuleBuilder.new.variation(0).clause(Clauses.match_segment(segment))
        ).build
        store = InMemoryFeatureStore.new
        store.upsert(SEGMENTS, segment)
        store.upsert(FEATURES, flag)

        with_client(test_config(feature_store: store)) do |client|
          expect(client.variation("flagkey", basic_user, false)).to be true
        end
      end

      it "can evaluate a flag that references a big segment" do
        segment = SegmentBuilder.new("segmentkey").unbounded(true).generation(1).build
        flag = FlagBuilder.new("flagkey").on(true).variations(true, false).rule(
          RuleBuilder.new.variation(0).clause(Clauses.match_segment(segment))
        ).build
        store = InMemoryFeatureStore.new
        store.upsert(SEGMENTS, segment)
        store.upsert(FEATURES, flag)

        segstore = MockBigSegmentStore.new
        segstore.setup_segment_for_user(basic_user[:key], segment, true)
        big_seg_config = BigSegmentsConfig.new(store: segstore)

        with_client(test_config(feature_store: store, big_segments: big_seg_config)) do |client|
          expect(client.variation("flagkey", basic_user, false)).to be true
        end
      end
    end

    context "variation_detail" do
      feature_with_value = { key: "key", on: false, offVariation: 0, variations: ["value"], version: 100,
        trackEvents: true, debugEventsUntilDate: 1000 }

      it "returns the default value if the client is offline" do
        with_client(test_config(offline: true)) do |offline_client|
          result = offline_client.variation_detail("doesntmatter", basic_user, "default")
          expected = EvaluationDetail.new("default", nil, EvaluationReason::error(EvaluationReason::ERROR_CLIENT_NOT_READY))
          expect(result).to eq expected
        end
      end

      it "returns the default value for an unknown feature" do
        with_client(test_config) do |client|
          result = client.variation_detail("badkey", basic_user, "default")
          expected = EvaluationDetail.new("default", nil, EvaluationReason::error(EvaluationReason::ERROR_FLAG_NOT_FOUND))
          expect(result).to eq expected
        end
      end

      it "returns a value for an existing feature" do
        flag = FlagBuilder.new("key").off_with_value("value").build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)

        with_client(test_config(feature_store: store)) do |client|
          result = client.variation_detail("key", basic_user, "default")
          expected = EvaluationDetail.new("value", 0, EvaluationReason::off)
          expect(result).to eq expected
        end
      end

      it "returns the default value if a feature evaluates to nil" do
        empty_feature = { key: "key", on: false, offVariation: nil }
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, empty_feature)

        with_client(test_config(feature_store: store)) do |client|
          result = client.variation_detail("key", basic_user, "default")
          expected = EvaluationDetail.new("default", nil, EvaluationReason::off)
          expect(result).to eq expected
          expect(result.default_value?).to be true
        end
      end

      it "includes big segment status in reason when evaluating a flag that references a big segment" do
        segment = SegmentBuilder.new("segmentkey").unbounded(true).generation(1).build
        flag = FlagBuilder.new("flagkey").on(true).variations(true, false).rule(
          RuleBuilder.new.variation(0).clause(Clauses.match_segment(segment))
        ).build
        store = InMemoryFeatureStore.new
        store.upsert(SEGMENTS, segment)
        store.upsert(FEATURES, flag)

        segstore = MockBigSegmentStore.new
        segstore.setup_segment_for_user(basic_user[:key], segment, true)
        segstore.setup_metadata(Time.now)
        big_seg_config = BigSegmentsConfig.new(store: segstore)

        with_client(test_config(feature_store: store, big_segments: big_seg_config)) do |client|
          result = client.variation_detail("flagkey", basic_user, false)
          expect(result.value).to be true
          expect(result.reason.big_segments_status).to eq(BigSegmentsStatus::HEALTHY)
        end
      end
    end

    describe "all_flags" do
      let(:flag1) { { key: "key1", offVariation: 0, variations: [ 'value1' ] } }
      let(:flag2) { { key: "key2", offVariation: 0, variations: [ 'value2' ] } }

      it "returns flag values" do
        store = InMemoryFeatureStore.new
        store.init({ FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

        with_client(test_config(feature_store: store)) do |client|
          result = client.all_flags({ key: 'userkey' })
          expect(result).to eq({ 'key1' => 'value1', 'key2' => 'value2' })
        end
      end

      it "returns empty map for nil user" do
        store = InMemoryFeatureStore.new
        store.init({ FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

        with_client(test_config(feature_store: store)) do |client|
          result = client.all_flags(nil)
          expect(result).to eq({})
        end
      end

      it "returns empty map for nil user key" do
        store = InMemoryFeatureStore.new
        store.init({ FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

        with_client(test_config(feature_store: store)) do |client|
          result = client.all_flags({})
          expect(result).to eq({})
        end
      end

      it "returns empty map if offline" do
        store = InMemoryFeatureStore.new
        store.init({ FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

        with_client(test_config(feature_store: store, offline: true)) do |offline_client|
          result = offline_client.all_flags(nil)
          expect(result).to eq({})
        end
      end
    end

    context "all_flags_state" do
      let(:flag1) { { key: "key1", version: 100, offVariation: 0, variations: [ 'value1' ], trackEvents: false } }
      let(:flag2) { { key: "key2", version: 200, offVariation: 1, variations: [ 'x', 'value2' ], trackEvents: true, debugEventsUntilDate: 1000 } }

      it "returns flags state" do
        store = InMemoryFeatureStore.new
        store.init({ FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

        with_client(test_config(feature_store: store)) do |client|
          state = client.all_flags_state({ key: 'userkey' })
          expect(state.valid?).to be true

          values = state.values_map
          expect(values).to eq({ 'key1' => 'value1', 'key2' => 'value2' })
          
          result = state.as_json
          expect(result).to eq({
            'key1' => 'value1',
            'key2' => 'value2',
            '$flagsState' => {
              'key1' => {
                :variation => 0,
                :version => 100
              },
              'key2' => {
                :variation => 1,
                :version => 200,
                :trackEvents => true,
                :debugEventsUntilDate => 1000
              }
            },
            '$valid' => true
          })
        end
      end

      it "can be filtered for only client-side flags" do
        flag1 = { key: "server-side-1", offVariation: 0, variations: [ 'a' ], clientSide: false }
        flag2 = { key: "server-side-2", offVariation: 0, variations: [ 'b' ], clientSide: false }
        flag3 = { key: "client-side-1", offVariation: 0, variations: [ 'value1' ], clientSide: true }
        flag4 = { key: "client-side-2", offVariation: 0, variations: [ 'value2' ], clientSide: true }

        store = InMemoryFeatureStore.new
        store.init({ FEATURES => {
          flag1[:key] => flag1, flag2[:key] => flag2, flag3[:key] => flag3, flag4[:key] => flag4
        }})

        with_client(test_config(feature_store: store)) do |client|
          state = client.all_flags_state({ key: 'userkey' }, client_side_only: true)
          expect(state.valid?).to be true

          values = state.values_map
          expect(values).to eq({ 'client-side-1' => 'value1', 'client-side-2' => 'value2' })
        end
      end

      it "can omit details for untracked flags" do
        future_time = (Time.now.to_f * 1000).to_i + 100000
        flag1 = { key: "key1", version: 100, offVariation: 0, variations: [ 'value1' ], trackEvents: false }
        flag2 = { key: "key2", version: 200, offVariation: 1, variations: [ 'x', 'value2' ], trackEvents: true }
        flag3 = { key: "key3", version: 300, offVariation: 1, variations: [ 'x', 'value3' ], debugEventsUntilDate: future_time }

        store = InMemoryFeatureStore.new
        store.init({ FEATURES => { 'key1' => flag1, 'key2' => flag2, 'key3' => flag3 } })

        with_client(test_config(feature_store: store)) do |client|
          state = client.all_flags_state({ key: 'userkey' }, { details_only_for_tracked_flags: true })
          expect(state.valid?).to be true

          values = state.values_map
          expect(values).to eq({ 'key1' => 'value1', 'key2' => 'value2', 'key3' => 'value3' })
          
          result = state.as_json
          expect(result).to eq({
            'key1' => 'value1',
            'key2' => 'value2',
            'key3' => 'value3',
            '$flagsState' => {
              'key1' => {
                :variation => 0
              },
              'key2' => {
                :variation => 1,
                :version => 200,
                :trackEvents => true
              },
              'key3' => {
                :variation => 1,
                :version => 300,
                :debugEventsUntilDate => future_time
              }
            },
            '$valid' => true
          })
        end
      end

      it "returns empty state for nil user" do
        store = InMemoryFeatureStore.new
        store.init({ FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

        with_client(test_config(feature_store: store)) do |client|
          state = client.all_flags_state(nil)
          expect(state.valid?).to be false
          expect(state.values_map).to eq({})
        end
      end

      it "returns empty state for nil user key" do
        store = InMemoryFeatureStore.new
        store.init({ FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

        with_client(test_config(feature_store: store)) do |client|
          state = client.all_flags_state({})
          expect(state.valid?).to be false
          expect(state.values_map).to eq({})
        end
      end

      it "returns empty state if offline" do
        store = InMemoryFeatureStore.new
        store.init({ FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

        with_client(test_config(feature_store: store, offline: true)) do |offline_client|
          state = offline_client.all_flags_state({ key: 'userkey' })
          expect(state.valid?).to be false
          expect(state.values_map).to eq({})
        end
      end
    end
  end
end
