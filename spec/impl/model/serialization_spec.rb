require "model_builders"
require "spec_helper"

module LaunchDarkly
  module Impl
    module Model
      describe "model serialization" do
        it "serializes flag" do
          flag = FlagBuilder.new("flagkey").version(1).build
          json = Model.serialize(FEATURES, flag)
          expect(JSON.parse(json, symbolize_names: true)).to eq flag.data
        end

        it "serializes segment" do
          segment = SegmentBuilder.new("segkey").version(1).build
          json = Model.serialize(SEGMENTS, segment)
          expect(JSON.parse(json, symbolize_names: true)).to eq segment.data
        end

        it "deserializes flag with no rules or prerequisites" do
          flag_in = { key: "flagkey", version: 1 }
          json = flag_in.to_json
          flag_out = Model.deserialize(FEATURES, json, nil)
          expect(flag_out.data).to eq flag_in
        end

        it "deserializes segment" do
          segment_in = { key: "segkey", version: 1 }
          json = segment_in.to_json
          segment_out = Model.deserialize(SEGMENTS, json, nil)
          expect(segment_out.data).to eq segment_in
        end
      end
    end
  end
end
