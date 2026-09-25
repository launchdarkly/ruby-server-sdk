# frozen_string_literal: true

require "spec_helper"
require "model_builders"
require "ldclient-rb/impl/overrides"
require "ldclient-rb/impl/data_store/in_memory_feature_store"

module LaunchDarkly
  module Impl
    module Overrides
      describe Overlay do
        let(:ld_a) { { key: "a", version: 1, on: false, offVariation: 0, variations: ["ld-a"] } }
        let(:ld_b) { { key: "b", version: 1, on: false, offVariation: 0, variations: ["ld-b"] } }
        let(:ld_deleted) { { key: "gone", version: 5, deleted: true } }
        let(:ld_segment) { { key: "s", version: 1, included: ["ld-user"] } }
        let(:override_a) { Flags.from_hash({ key: "a", version: 9, on: false, offVariation: 0, variations: ["override-a"] }) }
        let(:override_c) { Flags.from_hash({ key: "c", version: 1, on: false, offVariation: 0, variations: ["override-c"] }) }
        let(:override_gone) { Flags.from_hash({ key: "gone", version: 1, on: false, offVariation: 0, variations: ["back"] }) }
        let(:override_segment) { Segments.from_hash({ key: "s", version: 2, included: ["override-user"] }) }

        let(:base) { DataStore::InMemoryFeatureStoreV2.new($null_log) }
        let(:layer) { Layer.new }
        subject(:overlay) { Overlay.new(base, layer) }

        def load_base
          base.set_basis({
            DataStore::FEATURES => { a: ld_a, b: ld_b, gone: ld_deleted },
            DataStore::SEGMENTS => { s: ld_segment },
          })
        end

        it "is a read-only store" do
          expect(overlay).to be_a(Interfaces::DataSystem::ReadOnlyStore)
        end

        describe "get" do
          it "returns the override entry when the layer has the key" do
            load_base
            layer.set_all({ a: override_a }, { s: override_segment })

            flag = overlay.get(DataStore::FEATURES, "a")
            expect(flag.variations).to eq ["override-a"]
            expect(flag.override?).to be true
            segment = overlay.get(DataStore::SEGMENTS, :s)
            expect(segment.included).to eq ["override-user"]
            expect(segment.override?).to be true
          end

          it "returns the base entry when the layer does not have the key" do
            load_base
            layer.set_all({ a: override_a }, {})

            flag = overlay.get(DataStore::FEATURES, "b")
            expect(flag.variations).to eq ["ld-b"]
            expect(flag.override?).to be false
          end

          it "returns an override entry for a key the base holds as deleted" do
            load_base
            layer.set_all({ gone: override_gone }, {})

            expect(overlay.get(DataStore::FEATURES, "gone").variations).to eq ["back"]
          end

          it "returns nil for a key that neither side has" do
            load_base

            expect(overlay.get(DataStore::FEATURES, "missing")).to be_nil
          end

          it "serves an override entry when the base is not initialized" do
            layer.set_all({ c: override_c }, {})

            expect(base.initialized?).to be false
            expect(overlay.get(DataStore::FEATURES, "c").variations).to eq ["override-c"]
            expect(overlay.get(DataStore::FEATURES, "a")).to be_nil
          end
        end

        describe "all" do
          it "returns the base items when the layer is empty" do
            load_base

            items = overlay.all(DataStore::FEATURES)
            expect(items.keys.sort).to eq [:a, :b]
            expect(items[:a].variations).to eq ["ld-a"]
          end

          it "returns the union with the override entry winning for a shared key" do
            load_base
            layer.set_all({ a: override_a, c: override_c }, {})

            items = overlay.all(DataStore::FEATURES)
            expect(items.keys.sort).to eq [:a, :b, :c]
            expect(items[:a].variations).to eq ["override-a"]
            expect(items[:a].override?).to be true
            expect(items[:b].override?).to be false
            expect(items[:c].variations).to eq ["override-c"]
          end

          it "includes an override entry for a key the base holds as deleted" do
            load_base
            layer.set_all({ gone: override_gone }, {})

            expect(overlay.all(DataStore::FEATURES).keys.sort).to eq [:a, :b, :gone]
          end

          it "returns only the override entries when the base is not initialized" do
            layer.set_all({ c: override_c }, {})

            expect(overlay.all(DataStore::FEATURES).keys).to eq [:c]
            expect(overlay.all(DataStore::SEGMENTS)).to eq({})
          end

          it "returns the override entries alone when the base fails and the layer has entries" do
            failing = double("base")
            allow(failing).to receive(:all).and_raise(RuntimeError, "store down")
            overlay = Overlay.new(failing, layer)
            layer.set_all({ c: override_c }, {})

            expect(overlay.all(DataStore::FEATURES).keys).to eq [:c]
          end

          it "raises the base error when the base fails and the layer is empty" do
            failing = double("base")
            allow(failing).to receive(:all).and_raise(RuntimeError, "store down")
            overlay = Overlay.new(failing, layer)

            expect { overlay.all(DataStore::FEATURES) }.to raise_error(RuntimeError, "store down")
          end
        end

        describe "initialized?" do
          it "delegates to the base and ignores the layer" do
            layer.set_all({ c: override_c }, {})
            expect(overlay.initialized?).to be false

            load_base
            expect(overlay.initialized?).to be true
          end
        end
      end
    end
  end
end
