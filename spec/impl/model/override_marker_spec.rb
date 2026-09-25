require "spec_helper"
require "model_builders"

module LaunchDarkly
  module Impl
    module Model
      describe "override marker" do
        let(:flag_data) { { key: "flag1", version: 3, on: false, offVariation: 0, variations: ["a"] } }
        let(:segment_data) { { key: "seg1", version: 4, included: ["user1"] } }

        it "is not set on a flag or segment built from data" do
          expect(Flags.from_hash(flag_data).override?).to be false
          expect(Segments.from_hash(segment_data).override?).to be false
        end

        it "is not set on a deleted item" do
          expect(Flags.from_hash({ key: "flag1", version: 3, deleted: true }).override?).to be false
          expect(Segments.from_hash({ key: "seg1", version: 4, deleted: true }).override?).to be false
        end

        it "is set on the copy returned by as_override and not on the original" do
          flag = Flags.from_hash(flag_data)
          segment = Segments.from_hash(segment_data)

          marked_flag = flag.as_override
          marked_segment = segment.as_override

          expect(marked_flag.override?).to be true
          expect(marked_segment.override?).to be true
          expect(flag.override?).to be false
          expect(segment.override?).to be false
          expect(marked_flag).not_to be flag
          expect(marked_segment).not_to be segment
        end

        it "keeps the copy equal to the original and keeps its properties" do
          flag = Flags.from_hash(flag_data)
          marked = flag.as_override

          expect(marked).to eq flag
          expect(marked.key).to eq "flag1"
          expect(marked.version).to eq 3
          expect(marked.off_result).to eq flag.off_result
          expect(marked[:variations]).to eq ["a"]
        end

        it "does not serialize the marker" do
          flag = Flags.from_hash(flag_data)
          segment = Segments.from_hash(segment_data)

          expect(flag.as_override.to_json).to eq flag.to_json
          expect(segment.as_override.to_json).to eq segment.to_json
          expect(flag.as_override.as_json).to eq flag_data
          expect(segment.as_override.as_json).to eq segment_data
          expect(Model.serialize(DataStore::FEATURES, flag.as_override)).to eq Model.serialize(DataStore::FEATURES, flag)
        end

        it "keeps the marker on a copy of a marked item" do
          expect(Flags.from_hash(flag_data).as_override.as_override.override?).to be true
        end

        it "returns a marked item unchanged from deserialization" do
          marked = Flags.from_hash(flag_data).as_override

          expect(Model.deserialize(DataStore::FEATURES, marked)).to be marked
        end
      end
    end
  end
end
