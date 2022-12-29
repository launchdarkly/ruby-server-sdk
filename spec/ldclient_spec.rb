require "mock_components"
require "spec_helper"

module LaunchDarkly
  describe LDClient do
    subject { LDClient }

    context "constructor requirement of non-nil sdk key" do
      it "is not enforced when offline" do
        subject.new(nil, Config.new(offline: true))
      end

      it "is not enforced if use_ldd is true and send_events is false" do
        subject.new(nil, Config.new({ use_ldd: true, send_events: false }))
      end

      it "is not enforced if using file data and send_events is false" do
        source = LaunchDarkly::Integrations::FileData.data_source({})
        subject.new(nil, Config.new({ data_source: source, send_events: false }))
      end

      it "is enforced in streaming mode even if send_events is false" do
        expect {
          subject.new(nil, Config.new({ send_events: false }))
        }.to raise_error(ArgumentError)
      end

      it "is enforced in polling mode even if send_events is false" do
        expect {
          subject.new(nil, Config.new({ stream: false, send_events: false }))
        }.to raise_error(ArgumentError)
      end

      it "is enforced if use_ldd is true and send_events is true" do
        expect {
          subject.new(nil, Config.new({ use_ldd: true }))
        }.to raise_error(ArgumentError)
      end

      it "is enforced if using file data and send_events is true" do
        source = LaunchDarkly::Integrations::FileData.data_source({})
        expect {
          subject.new(nil, Config.new({ data_source: source }))
        }.to raise_error(ArgumentError)
      end
    end

    context "secure_mode_hash" do
      it "will return the expected value for a known message and secret" do
        ensure_close(subject.new("secret", test_config)) do |client|
          result = client.secure_mode_hash({key: :Message})
          expect(result).to eq "aa747c502a898200f9e4fa21bac68136f886a0e27aec70ba06daf2e2a5cb5597"
        end
      end
    end

    context "feature store data ordering" do
      let(:dependency_ordering_test_data) {
        {
          FEATURES => {
            a: { key: "a", prerequisites: [ { key: "b" }, { key: "c" } ] },
            b: { key: "b", prerequisites: [ { key: "c" }, { key: "e" } ] },
            c: { key: "c" },
            d: { key: "d" },
            e: { key: "e" },
            f: { key: "f" },
          },
          SEGMENTS => {
            o: { key: "o" },
          },
        }
      }

      it "passes data set to feature store in correct order on init" do
        store = CapturingFeatureStore.new
        td = Integrations::TestData.data_source
        dependency_ordering_test_data[FEATURES].each { |key, flag| td.use_preconfigured_flag(flag) }
        dependency_ordering_test_data[SEGMENTS].each { |key, segment| td.use_preconfigured_segment(segment) }

        with_client(test_config(feature_store: store, data_source: td)) do |client|
          data = store.received_data
          expect(data).not_to be_nil
          expect(data.count).to eq(2)

          # Segments should always come first
          expect(data.keys[0]).to be(SEGMENTS)
          expect(data.values[0].count).to eq(dependency_ordering_test_data[SEGMENTS].count)

          # Features should be ordered so that a flag always appears after its prerequisites, if any
          expect(data.keys[1]).to be(FEATURES)
          flags_map = data.values[1]
          flags_list = flags_map.values
          expect(flags_list.count).to eq(dependency_ordering_test_data[FEATURES].count)
          flags_list.each_with_index do |item, item_index|
            (item[:prerequisites] || []).each do |prereq|
              prereq = flags_map[prereq[:key].to_sym]
              prereq_index = flags_list.index(prereq)
              if prereq_index > item_index
                all_keys = (flags_list.map { |f| f[:key] }).join(", ")
                raise "#{item[:key]} depends on #{prereq[:key]}, but #{item[:key]} was listed first; keys in order are [#{all_keys}]"
              end
            end
          end
        end
      end
    end
  end
end