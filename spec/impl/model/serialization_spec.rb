require "model_builders"
require "spec_helper"

module LaunchDarkly
  module Impl
    module Model
      describe "model serialization" do
        factory = DataItemFactory.new(true)  # true = enable the usual preprocessing logic

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
          flag_preprocessed = factory.flag(flag_in)
          json = Model.serialize(FEATURES, flag_preprocessed)
          flag_out = Model.deserialize(FEATURES, json)
          expect(flag_out).to eq flag_preprocessed
        end

        it "deserializes segment" do
          segment_in = { key: "segkey", version: 1 }
          segment_preprocessed = factory.segment(segment_in)
          json = Model.serialize(SEGMENTS, segment_preprocessed)
          segment_out = Model.deserialize(SEGMENTS, json)
          expect(segment_out).to eq factory.segment(segment_preprocessed)
        end
      end
    end
  end
end
