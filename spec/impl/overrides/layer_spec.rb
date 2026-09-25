# frozen_string_literal: true

require "spec_helper"
require "model_builders"
require "ldclient-rb/impl/overrides"

module LaunchDarkly
  module Impl
    module Overrides
      describe Layer do
        let(:flag_a) { Flags.from_hash({ key: "a", version: 1, on: false, offVariation: 0, variations: ["a"] }) }
        let(:flag_b) { Flags.from_hash({ key: "b", version: 2, on: false, offVariation: 0, variations: ["b"] }) }
        let(:segment_s) { Segments.from_hash({ key: "s", version: 3, included: ["user"] }) }

        subject(:layer) { Layer.new }

        it "is empty when created" do
          expect(layer.empty?).to be true
          expect(layer.get(DataStore::FEATURES, "a")).to be_nil
          expect(layer.all(DataStore::FEATURES)).to eq({})
          expect(layer.all(DataStore::SEGMENTS)).to eq({})
        end

        it "stores marked copies and leaves the caller's objects unmarked" do
          layer.set_all({ a: flag_a }, { s: segment_s })

          stored_flag = layer.get(DataStore::FEATURES, "a")
          stored_segment = layer.get(DataStore::SEGMENTS, :s)
          expect(stored_flag.override?).to be true
          expect(stored_segment.override?).to be true
          expect(stored_flag).to eq flag_a
          expect(stored_flag).not_to be flag_a
          expect(flag_a.override?).to be false
          expect(segment_s.override?).to be false
          expect(layer.empty?).to be false
        end

        it "reads keys given as strings or symbols" do
          layer.set_all({ a: flag_a }, {})

          expect(layer.get(DataStore::FEATURES, "a")).to eq flag_a
          expect(layer.get(DataStore::FEATURES, :a)).to eq flag_a
        end

        it "returns nil for a key that is not overridden and for an unknown kind" do
          layer.set_all({ a: flag_a }, {})

          expect(layer.get(DataStore::FEATURES, "b")).to be_nil
          expect(layer.get(DataStore::SEGMENTS, "a")).to be_nil
          expect(layer.get(DataStore::DataKind.new(namespace: "other", priority: 9), "a")).to be_nil
        end

        it "replaces the whole contents on each update" do
          layer.set_all({ a: flag_a }, { s: segment_s })
          layer.set_all({ b: flag_b }, {})

          expect(layer.get(DataStore::FEATURES, "a")).to be_nil
          expect(layer.get(DataStore::FEATURES, "b")).to eq flag_b
          expect(layer.all(DataStore::SEGMENTS)).to eq({})
        end

        it "is cleared by an empty snapshot" do
          layer.set_all({ a: flag_a }, { s: segment_s })
          layer.set_all({}, {})

          expect(layer.empty?).to be true
          expect(layer.get(DataStore::FEATURES, "a")).to be_nil
        end

        it "returns the previous and the new contents from an update" do
          previous, current = layer.set_all({ a: flag_a }, {})
          expect(previous[DataStore::FEATURES]).to eq({})
          expect(current[DataStore::FEATURES].keys).to eq([:a])

          previous, current = layer.set_all({ b: flag_b }, { s: segment_s })
          expect(previous[DataStore::FEATURES].keys).to eq([:a])
          expect(current[DataStore::FEATURES].keys).to eq([:b])
          expect(current[DataStore::SEGMENTS].keys).to eq([:s])
        end

        it "returns frozen contents that cannot be modified" do
          layer.set_all({ a: flag_a }, {})

          expect(layer.contents).to be_frozen
          expect(layer.all(DataStore::FEATURES)).to be_frozen
        end

        it "always shows a reader exactly one snapshot" do
          snapshot_one = { a: flag_a }
          snapshot_two = { b: flag_b }
          stop = Concurrent::AtomicBoolean.new(false)
          mixed = Concurrent::AtomicBoolean.new(false)

          writer = Thread.new do
            i = 0
            until stop.value
              layer.set_all(i.even? ? snapshot_one : snapshot_two, {})
              i += 1
            end
          end
          reader = Thread.new do
            until stop.value
              keys = layer.all(DataStore::FEATURES).keys
              mixed.make_true unless [[], [:a], [:b]].include?(keys)
            end
          end

          sleep 0.3
          stop.make_true
          [writer, reader].each(&:join)

          expect(mixed.value).to be false
        end
      end
    end
  end
end
