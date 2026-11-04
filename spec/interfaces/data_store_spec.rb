require "spec_helper"

module LaunchDarkly
  module Interfaces
    module DataStore
      describe DataKind do
        describe "serialize and deserialize" do
          it "round-trips a feature flag" do
            json = '{"key":"flag","version":3,"on":true}'
            flag = FEATURES.deserialize(json)
            expect(flag).to be_a(LaunchDarkly::Impl::Model::FeatureFlag)
            expect(flag[:version]).to eq 3
            expect(JSON.parse(FEATURES.serialize(flag))).to eq JSON.parse(json)
          end

          it "round-trips a segment" do
            json = '{"key":"segment","version":2,"included":["a"]}'
            segment = SEGMENTS.deserialize(json)
            expect(segment).to be_a(LaunchDarkly::Impl::Model::Segment)
            expect(segment[:version]).to eq 2
            expect(JSON.parse(SEGMENTS.serialize(segment))).to eq JSON.parse(json)
          end

          it "round-trips a deleted item placeholder" do
            json = '{"key":"flag","version":4,"deleted":true}'
            item = FEATURES.deserialize(json)
            expect(item[:deleted]).to be true
            expect(item[:version]).to eq 4
            expect(JSON.parse(FEATURES.serialize(item))).to eq JSON.parse(json)
          end

          it "deserializes nil to nil" do
            expect(FEATURES.deserialize(nil)).to be_nil
          end
        end

        describe "eql?" do
          it "constant instances are equal to themselves" do
            expect(FEATURES.eql?(FEATURES)).to be true
            expect(SEGMENTS.eql?(SEGMENTS)).to be true
          end

          it "same constructions are equal" do
            expect(FEATURES.eql?(DataKind.new(namespace: "features", priority: 1))).to be true
            expect(DataKind.new(namespace: "features", priority: 1).eql?(DataKind.new(namespace: "features", priority: 1))).to be true

            expect(SEGMENTS.eql?(DataKind.new(namespace: "segments", priority: 0))).to be true
            expect(DataKind.new(namespace: "segments", priority: 0).eql?(DataKind.new(namespace: "segments", priority: 0))).to be true
          end

          it "distinct namespaces are not equal" do
            expect(DataKind.new(namespace: "features", priority: 1).eql?(DataKind.new(namespace: "segments", priority: 1))).to be false
          end

          it "distinct priorities are not equal" do
            expect(DataKind.new(namespace: "features", priority: 1).eql?(DataKind.new(namespace: "features", priority: 2))).to be false
            expect(DataKind.new(namespace: "segments", priority: 1).eql?(DataKind.new(namespace: "segments", priority: 2))).to be false
          end

          it "handles non-DataKind objects" do
            ["example", true, 1, 1.0, [], {}].each do |obj|
              expect(FEATURES.eql?(obj)).to be false
            end
          end
        end

        describe "==" do
          it "same constructions are equal" do
            expect(DataKind.new(namespace: "features", priority: 1)).to eq FEATURES
            expect(DataKind.new(namespace: "segments", priority: 0)).to eq SEGMENTS
          end

          it "a kind that went through Marshal is equal" do
            expect(Marshal.load(Marshal.dump(FEATURES))).to eq FEATURES
          end

          it "distinct kinds are not equal" do
            expect(DataKind.new(namespace: "features", priority: 2)).not_to eq FEATURES
            expect(FEATURES).not_to eq SEGMENTS
            expect(FEATURES).not_to eq "features"
          end

          it "ALL_KINDS includes an equal kind" do
            expect(ALL_KINDS).to include(DataKind.new(namespace: "segments", priority: 0))
          end

          it "an equal kind deserializes to the model class" do
            kind = DataKind.new(namespace: "features", priority: 1)
            expect(kind.deserialize('{"key":"flag","version":1}')).to be_a(LaunchDarkly::Impl::Model::FeatureFlag)
          end
        end

        describe "hash" do
          it "constant instances are equal to themselves" do
            expect(FEATURES.hash).to eq FEATURES.hash
            expect(SEGMENTS.hash).to eq SEGMENTS.hash
          end

          it "same constructions are equal" do
            expect(FEATURES.hash).to eq DataKind.new(namespace: "features", priority: 1).hash
            expect(DataKind.new(namespace: "features", priority: 1).hash).to eq DataKind.new(namespace: "features", priority: 1).hash

            expect(SEGMENTS.hash).to eq DataKind.new(namespace: "segments", priority: 0).hash
            expect(DataKind.new(namespace: "segments", priority: 0).hash).to eq DataKind.new(namespace: "segments", priority: 0).hash
          end

          it "distinct namespaces are not equal" do
            expect(DataKind.new(namespace: "features", priority: 1).hash).not_to eq DataKind.new(namespace: "segments", priority: 1).hash
          end

          it "distinct priorities are not equal" do
            expect(DataKind.new(namespace: "features", priority: 1).hash).not_to eq DataKind.new(namespace: "features", priority: 2).hash
            expect(DataKind.new(namespace: "segments", priority: 1).hash).not_to eq DataKind.new(namespace: "segments", priority: 2).hash
          end
        end
      end

      describe SerializedItemDescriptor do
        it "keeps its values" do
          descriptor = SerializedItemDescriptor.new(version: 5, deleted: false, serialized_item: "{}")
          expect(descriptor.version).to eq 5
          expect(descriptor.deleted).to be false
          expect(descriptor.serialized_item).to eq "{}"
        end

        it "compares by value" do
          expect(SerializedItemDescriptor.new(version: 1, deleted: true, serialized_item: nil))
            .to eq SerializedItemDescriptor.new(version: 1, deleted: true, serialized_item: nil)
        end
      end
    end
  end
end
