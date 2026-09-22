require "model_builders"
require "spec_helper"

module LaunchDarkly
  module Impl
    module Model
      describe "model serialization" do
        it "serializes flag" do
          flag = FlagBuilder.new("flagkey").version(1).build
          json = Model.serialize(Impl::DataStore::FEATURES, flag)
          expect(JSON.parse(json, symbolize_names: true)).to eq flag.data
        end

        it "serializes segment" do
          segment = SegmentBuilder.new("segkey").version(1).build
          json = Model.serialize(Impl::DataStore::SEGMENTS, segment)
          expect(JSON.parse(json, symbolize_names: true)).to eq segment.data
        end

        it "deserializes flag with no rules or prerequisites" do
          flag_in = { key: "flagkey", version: 1 }
          json = flag_in.to_json
          flag_out = Model.deserialize(Impl::DataStore::FEATURES, json, nil)
          expect(flag_out.data).to eq flag_in
        end

        it "deserializes segment" do
          segment_in = { key: "segkey", version: 1 }
          json = segment_in.to_json
          segment_out = Model.deserialize(Impl::DataStore::SEGMENTS, json, nil)
          expect(segment_out.data).to eq segment_in
        end

        # Other LaunchDarkly SDKs write a deleted item to a persistent store with only a version,
        # and no key of its own. The store knows the key, because it is the key the item is stored
        # under, so a tombstone must deserialize without one.
        [ Impl::DataStore::FEATURES, Impl::DataStore::SEGMENTS ].each do |kind|
          it "deserializes a tombstone with no key for #{kind[:namespace]}" do
            item_in = { version: 99, deleted: true }
            item_out = Model.deserialize(kind, item_in.to_json, nil)

            expect(item_out.key).to be_nil
            expect(item_out.version).to eq 99
            expect(item_out.deleted).to be true
            # The store re-serializes what it read, so the original data must survive unchanged.
            expect(item_out.data).to eq item_in
          end

          it "deserializes a tombstone with a placeholder key for #{kind[:namespace]}" do
            # The Go SDK and the Relay Proxy write a deleted item as a full object whose key is
            # the placeholder "$deleted".
            item_in = { key: "$deleted", version: 99, deleted: true }
            item_out = Model.deserialize(kind, item_in.to_json, nil)

            expect(item_out.key).to eq "$deleted"
            expect(item_out.deleted).to be true
            expect(item_out.data).to eq item_in
          end
        end
      end
    end
  end
end
