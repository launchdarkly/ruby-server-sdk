require "spec_helper"
require "ldclient-rb/impl/data_store/in_memory_feature_store"
require "ldclient-rb/impl/data_store"

module LaunchDarkly
  module Impl
    module DataStore
      describe InMemoryFeatureStoreV2 do
        let(:logger) { double.as_null_object }
        subject { InMemoryFeatureStoreV2.new(logger) }

        let(:flag_key) { "test-flag" }
        let(:flag) do
          {
            key: flag_key,
            version: 1,
            on: true,
            fallthrough: { variation: 0 },
            variations: [true, false],
          }
        end

        describe "#get with string/symbol key compatibility" do
          before do
            # Store items with symbol keys (as done by FDv2 protocol layer)
            collections = {
              FEATURES => { flag_key.to_sym => flag },
            }
            subject.set_basis(collections)
          end

          it "retrieves items with string keys (critical for variation calls)" do
            result = subject.get(FEATURES, flag_key)
            expect(result).to be_a(LaunchDarkly::Impl::Model::FeatureFlag)
            expect(result.key).to eq(flag_key)
          end

          it "retrieves items with symbol keys" do
            result = subject.get(FEATURES, flag_key.to_sym)
            expect(result).to be_a(LaunchDarkly::Impl::Model::FeatureFlag)
            expect(result.key).to eq(flag_key)
          end

          it "returns nil for non-existent keys" do
            expect(subject.get(FEATURES, "nonexistent")).to be_nil
          end
        end
      end
    end
  end
end
