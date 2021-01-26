require "spec_helper"

module LaunchDarkly
  module Impl
    module Model
      describe "model serialization" do
        it "serializes flag" do
          flag = { key: "flagkey", version: 1 }
          json = Model.serialize(FEATURES, flag)
          expect(JSON.parse(json, symbolize_names: true)).to eq flag
        end

        it "serializes segment" do
          segment = { key: "segkey", version: 1 }
          json = Model.serialize(SEGMENTS, segment)
          expect(JSON.parse(json, symbolize_names: true)).to eq segment
        end

        it "serializes arbitrary data kind" do
          thing = { key: "thingkey", name: "me" }
          json = Model.serialize({ name: "things" }, thing)
          expect(JSON.parse(json, symbolize_names: true)).to eq thing
        end

        it "deserializes flag with no rules or prerequisites" do
          flag_in = { key: "flagkey", version: 1 }
          json = Model.serialize(FEATURES, flag_in)
          flag_out = Model.deserialize(FEATURES, json)
          expect(flag_out).to eq flag_in
        end

        it "deserializes segment" do
          segment_in = { key: "segkey", version: 1 }
          json = Model.serialize(SEGMENTS, segment_in)
          segment_out = Model.deserialize(SEGMENTS, json)
          expect(segment_out).to eq segment_in
        end
      end
    end
  end
end
