require "ldclient-rb"

require "mock_components"
require "model_builders"
require "spec_helper"

module LaunchDarkly
  describe "LDClient evaluation tests" do
    context "variation" do
      it "returns the default value if the client is offline" do
        with_client(test_config(offline: true)) do |offline_client|
          result = offline_client.variation("doesntmatter", basic_context, "default")
          expect(result).to eq "default"
        end
      end

      it "returns the default value for an unknown feature" do
        with_client(test_config) do |client|
          expect(client.variation("badkey", basic_context, "default")).to eq "default"
        end
      end

      it "returns the value for an existing feature" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("value").variation_for_all(0))

        with_client(test_config(data_source: td)) do |client|
          expect(client.variation("flagkey", basic_context, "default")).to eq "value"
        end
      end

      it "returns the default value if a feature evaluates to nil" do
        td = Integrations::TestData.data_source
        td.use_preconfigured_flag({  # TestData normally won't construct a flag with offVariation: nil
          key: "flagkey",
          on: false,
          offVariation: nil,
        })

        with_client(test_config(data_source: td)) do |client|
          expect(client.variation("flagkey", basic_context, "default")).to eq "default"
        end
      end

      it "can evaluate a flag that references a segment" do
        td = Integrations::TestData.data_source
        segment = SegmentBuilder.new("segmentkey").included(basic_context.key).build
        td.use_preconfigured_segment(segment)
        td.use_preconfigured_flag(
          FlagBuilder.new("flagkey").on(true).variations(true, false).rule(
            RuleBuilder.new.variation(0).clause(Clauses.match_segment(segment))
          ).build)

        with_client(test_config(data_source: td)) do |client|
          expect(client.variation("flagkey", basic_context, false)).to be true
        end
      end

      it "can evaluate a flag that references a big segment" do
        td = Integrations::TestData.data_source
        segment = SegmentBuilder.new("segmentkey").unbounded(true).generation(1).build
        td.use_preconfigured_segment(segment)
        td.use_preconfigured_flag(
          FlagBuilder.new("flagkey").on(true).variations(true, false).rule(
            RuleBuilder.new.variation(0).clause(Clauses.match_segment(segment))
          ).build)

        segstore = MockBigSegmentStore.new
        segstore.setup_segment_for_context(basic_context.key, segment, true)
        big_seg_config = BigSegmentsConfig.new(store: segstore)

        with_client(test_config(data_source: td, big_segments: big_seg_config)) do |client|
          expect(client.variation("flagkey", basic_context, false)).to be true
        end
      end
    end

    context "variation_detail" do
      feature_with_value = { key: "key", on: false, offVariation: 0, variations: ["value"], version: 100,
        trackEvents: true, debugEventsUntilDate: 1000 }

      it "returns the default value if the client is offline" do
        with_client(test_config(offline: true)) do |offline_client|
          result = offline_client.variation_detail("doesntmatter", basic_context, "default")
          expected = EvaluationDetail.new("default", nil, EvaluationReason::error(EvaluationReason::ERROR_CLIENT_NOT_READY))
          expect(result).to eq expected
        end
      end

      it "returns the default value for an unknown feature" do
        with_client(test_config) do |client|
          result = client.variation_detail("badkey", basic_context, "default")
          expected = EvaluationDetail.new("default", nil, EvaluationReason::error(EvaluationReason::ERROR_FLAG_NOT_FOUND))
          expect(result).to eq expected
        end
      end

      it "returns a value for an existing feature" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("value").on(false).off_variation(0))

        with_client(test_config(data_source: td)) do |client|
          result = client.variation_detail("flagkey", basic_context, "default")
          expected = EvaluationDetail.new("value", 0, EvaluationReason::off)
          expect(result).to eq expected
        end
      end

      it "returns the default value if a feature evaluates to nil" do
        td = Integrations::TestData.data_source
        td.use_preconfigured_flag({  # TestData normally won't construct a flag with offVariation: nil
          key: "flagkey",
          on: false,
          offVariation: nil,
        })

        with_client(test_config(data_source: td)) do |client|
          result = client.variation_detail("flagkey", basic_context, "default")
          expected = EvaluationDetail.new("default", nil, EvaluationReason::off)
          expect(result).to eq expected
          expect(result.default_value?).to be true
        end
      end

      it "includes big segment status in reason when evaluating a flag that references a big segment" do
        td = Integrations::TestData.data_source
        segment = SegmentBuilder.new("segmentkey").unbounded(true).generation(1).build
        td.use_preconfigured_segment(segment)
        td.use_preconfigured_flag(
          FlagBuilder.new("flagkey").on(true).variations(true, false).rule(
            RuleBuilder.new.variation(0).clause(Clauses.match_segment(segment))
          ).build)

        segstore = MockBigSegmentStore.new
        segstore.setup_segment_for_context(basic_context.key, segment, true)
        segstore.setup_metadata(Time.now)
        big_seg_config = BigSegmentsConfig.new(store: segstore)

        with_client(test_config(data_source: td, big_segments: big_seg_config)) do |client|
          result = client.variation_detail("flagkey", basic_context, false)
          expect(result.value).to be true
          expect(result.reason.big_segments_status).to eq(BigSegmentsStatus::HEALTHY)
        end
      end
    end

    context "all_flags_state" do
      let(:flag1) { { key: "key1", version: 100, offVariation: 0, variations: [ 'value1' ], trackEvents: false } }
      let(:flag2) { { key: "key2", version: 200, offVariation: 1, variations: [ 'x', 'value2' ], trackEvents: true, debugEventsUntilDate: 1000 } }
      let(:test_data) {
        td = Integrations::TestData.data_source
        td.use_preconfigured_flag(flag1)
        td.use_preconfigured_flag(flag2)
        td
      }

      it "returns flags state" do

        with_client(test_config(data_source: test_data)) do |client|
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
                :version => 100,
              },
              'key2' => {
                :variation => 1,
                :version => 200,
                :trackEvents => true,
                :debugEventsUntilDate => 1000,
              },
            },
            '$valid' => true,
          })
        end
      end

      it "can be filtered for only client-side flags" do
        td = Integrations::TestData.data_source
        td.use_preconfigured_flag({ key: "server-side-1", offVariation: 0, variations: [ 'a' ], clientSide: false })
        td.use_preconfigured_flag({ key: "server-side-2", offVariation: 0, variations: [ 'b' ], clientSide: false })
        td.use_preconfigured_flag({ key: "client-side-1", offVariation: 0, variations: [ 'value1' ], clientSide: true })
        td.use_preconfigured_flag({ key: "client-side-2", offVariation: 0, variations: [ 'value2' ], clientSide: true })

        with_client(test_config(data_source: td)) do |client|
          state = client.all_flags_state({ key: 'userkey' }, client_side_only: true)
          expect(state.valid?).to be true

          values = state.values_map
          expect(values).to eq({ 'client-side-1' => 'value1', 'client-side-2' => 'value2' })
        end
      end

      it "can omit details for untracked flags" do
        future_time = (Time.now.to_f * 1000).to_i + 100000
        td = Integrations::TestData.data_source
        td.use_preconfigured_flag({ key: "key1", version: 100, offVariation: 0, variations: [ 'value1' ], trackEvents: false })
        td.use_preconfigured_flag({ key: "key2", version: 200, offVariation: 1, variations: [ 'x', 'value2' ], trackEvents: true })
        td.use_preconfigured_flag({ key: "key3", version: 300, offVariation: 1, variations: [ 'x', 'value3' ], debugEventsUntilDate: future_time })

        with_client(test_config(data_source: td)) do |client|
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
                :variation => 0,
              },
              'key2' => {
                :variation => 1,
                :version => 200,
                :trackEvents => true,
              },
              'key3' => {
                :variation => 1,
                :version => 300,
                :debugEventsUntilDate => future_time,
              },
            },
            '$valid' => true,
          })
        end
      end

      it "returns empty state for nil context" do
        with_client(test_config(data_source: test_data)) do |client|
          state = client.all_flags_state(nil)
          expect(state.valid?).to be false
          expect(state.values_map).to eq({})
        end
      end

      it "returns empty state for nil context key" do
        with_client(test_config(data_source: test_data)) do |client|
          state = client.all_flags_state({})
          expect(state.valid?).to be false
          expect(state.values_map).to eq({})
        end
      end

      it "returns empty state if offline" do
        with_client(test_config(data_source: test_data, offline: true)) do |offline_client|
          state = offline_client.all_flags_state({ key: 'userkey' })
          expect(state.valid?).to be false
          expect(state.values_map).to eq({})
        end
      end

      it "returns empty state if store is not initialize" do
        wait = double
        expect(wait).to receive(:wait).at_least(:once)

        source = double
        expect(source).to receive(:start).at_least(:once).and_return(wait)
        expect(source).to receive(:stop).at_least(:once).and_return(wait)
        expect(source).to receive(:initialized?).at_least(:once).and_return(false)
        store = LaunchDarkly::InMemoryFeatureStore.new
        with_client(test_config(store: store, data_source: source)) do |offline_client|
          state = offline_client.all_flags_state({ key: 'userkey' })
          expect(state.valid?).to be false
          expect(state.values_map).to eq({})
        end
      end
    end
  end
end
