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

        let(:segment_key) { "test-segment" }
        let(:segment) do
          {
            key: segment_key,
            version: 1,
            included: ["user1"],
            excluded: [],
            rules: [],
          }
        end

        describe "#initialized?" do
          it "returns false before initialization" do
            expect(subject.initialized?).to be false
          end

          it "returns true after set_basis" do
            subject.set_basis({ FEATURES => {} })
            expect(subject.initialized?).to be true
          end
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

          it "returns nil for deleted items" do
            deleted_flag = flag.merge(deleted: true)
            collections = { FEATURES => { flag_key.to_sym => deleted_flag } }
            subject.set_basis(collections)
            expect(subject.get(FEATURES, flag_key)).to be_nil
          end
        end

        describe "#all" do
          it "returns empty hash when no data" do
            expect(subject.all(FEATURES)).to eq({})
          end

          it "returns all non-deleted items" do
            collections = {
              FEATURES => {
                flag_key.to_sym => flag,
                "deleted-flag".to_sym => flag.merge(key: "deleted-flag", deleted: true),
              },
            }
            subject.set_basis(collections)

            result = subject.all(FEATURES)
            expect(result.keys).to contain_exactly(flag_key.to_sym)
            expect(result[flag_key.to_sym].key).to eq(flag_key)
          end

          it "returns items for both flags and segments" do
            collections = {
              FEATURES => { flag_key.to_sym => flag },
              SEGMENTS => { segment_key.to_sym => segment },
            }
            subject.set_basis(collections)

            expect(subject.all(FEATURES).keys).to contain_exactly(flag_key.to_sym)
            expect(subject.all(SEGMENTS).keys).to contain_exactly(segment_key.to_sym)
          end
        end

        describe "#set_basis" do
          it "initializes the store with valid data" do
            collections = {
              FEATURES => { flag_key.to_sym => flag },
              SEGMENTS => { segment_key.to_sym => segment },
            }

            result = subject.set_basis(collections)
            expect(result).to be true
            expect(subject.initialized?).to be true
            expect(subject.get(FEATURES, flag_key)).not_to be_nil
            expect(subject.get(SEGMENTS, segment_key)).not_to be_nil
          end

          it "replaces existing data" do
            # Set initial data
            initial_collections = {
              FEATURES => { flag_key.to_sym => flag },
            }
            subject.set_basis(initial_collections)

            # Replace with new data
            new_flag = flag.merge(key: "new-flag", version: 2)
            new_collections = {
              FEATURES => { "new-flag".to_sym => new_flag },
            }
            result = subject.set_basis(new_collections)

            expect(result).to be true
            expect(subject.get(FEATURES, flag_key)).to be_nil  # Old flag gone
            expect(subject.get(FEATURES, "new-flag")).not_to be_nil
          end

          it "clears all data before setting new data" do
            subject.set_basis({
              FEATURES => { flag_key.to_sym => flag },
              SEGMENTS => { segment_key.to_sym => segment },
            })

            # Replace with data that only has flags
            new_collections = {
              FEATURES => { "new-flag".to_sym => flag.merge(key: "new-flag") },
              SEGMENTS => {},
            }
            subject.set_basis(new_collections)

            expect(subject.all(SEGMENTS)).to be_empty
          end

          it "handles multiple flags and segments" do
            flag1 = flag.merge(key: "flag-1")
            flag2 = flag.merge(key: "flag-2", version: 2)
            flag3 = flag.merge(key: "flag-3", version: 3)

            segment1 = segment.merge(key: "segment-1")
            segment2 = segment.merge(key: "segment-2", version: 2)

            collections = {
              FEATURES => {
                "flag-1".to_sym => flag1,
                "flag-2".to_sym => flag2,
                "flag-3".to_sym => flag3,
              },
              SEGMENTS => {
                "segment-1".to_sym => segment1,
                "segment-2".to_sym => segment2,
              },
            }

            result = subject.set_basis(collections)
            expect(result).to be true

            expect(subject.all(FEATURES).size).to eq(3)
            expect(subject.all(SEGMENTS).size).to eq(2)
          end

          it "returns false and logs error on deserialization failure" do
            allow(LaunchDarkly::Impl::Model).to receive(:deserialize).and_raise(StandardError.new("test error"))

            collections = { FEATURES => { flag_key.to_sym => flag } }
            result = subject.set_basis(collections)

            expect(result).to be false
            expect(subject.initialized?).to be false
          end

          it "handles empty collections" do
            result = subject.set_basis({ FEATURES => {}, SEGMENTS => {} })
            expect(result).to be true
            expect(subject.initialized?).to be true
          end
        end

        describe "#apply_delta" do
          before do
            # Set initial data
            collections = {
              FEATURES => { flag_key.to_sym => flag },
              SEGMENTS => { segment_key.to_sym => segment },
            }
            subject.set_basis(collections)
          end

          it "adds new items without clearing existing data" do
            new_flag = flag.merge(key: "new-flag", version: 2)
            delta = {
              FEATURES => { "new-flag".to_sym => new_flag },
            }

            result = subject.apply_delta(delta)
            expect(result).to be true

            # Original flag should still exist
            expect(subject.get(FEATURES, flag_key)).not_to be_nil
            # New flag should be added
            expect(subject.get(FEATURES, "new-flag")).not_to be_nil
            # Segment should be unchanged
            expect(subject.get(SEGMENTS, segment_key)).not_to be_nil
          end

          it "updates existing items" do
            updated_flag = flag.merge(version: 2, on: false)
            delta = {
              FEATURES => { flag_key.to_sym => updated_flag },
            }

            result = subject.apply_delta(delta)
            expect(result).to be true

            result = subject.get(FEATURES, flag_key)
            expect(result.version).to eq(2)
            expect(result.on).to be false
          end

          it "handles multiple updates in one delta" do
            flag2 = flag.merge(key: "flag-2", version: 2)
            flag3 = flag.merge(key: "flag-3", version: 3)
            segment2 = segment.merge(key: "segment-2", version: 2)

            delta = {
              FEATURES => {
                "flag-2".to_sym => flag2,
                "flag-3".to_sym => flag3,
              },
              SEGMENTS => {
                "segment-2".to_sym => segment2,
              },
            }

            result = subject.apply_delta(delta)
            expect(result).to be true

            # Original items unchanged
            expect(subject.get(FEATURES, flag_key)).not_to be_nil
            expect(subject.get(SEGMENTS, segment_key)).not_to be_nil

            # New items added
            expect(subject.get(FEATURES, "flag-2")).not_to be_nil
            expect(subject.get(FEATURES, "flag-3")).not_to be_nil
            expect(subject.get(SEGMENTS, "segment-2")).not_to be_nil
          end

          it "handles delete operations" do
            deleted_flag = { key: flag_key, version: 2, deleted: true }
            delta = {
              FEATURES => { flag_key.to_sym => deleted_flag },
            }

            result = subject.apply_delta(delta)
            expect(result).to be true

            # Deleted flag should return nil
            expect(subject.get(FEATURES, flag_key)).to be_nil
          end

          it "returns false and logs error on deserialization failure" do
            allow(LaunchDarkly::Impl::Model).to receive(:deserialize).and_raise(StandardError.new("test error"))

            delta = { FEATURES => { "new-flag".to_sym => flag } }
            result = subject.apply_delta(delta)

            expect(result).to be false
            # Original data should be intact
            expect(subject.get(FEATURES, flag_key)).not_to be_nil
          end

          it "handles empty delta" do
            result = subject.apply_delta({ FEATURES => {}, SEGMENTS => {} })
            expect(result).to be true

            # Original data unchanged
            expect(subject.get(FEATURES, flag_key)).not_to be_nil
            expect(subject.get(SEGMENTS, segment_key)).not_to be_nil
          end
        end

        describe "thread safety" do
          it "handles concurrent reads and writes" do
            subject.set_basis({ FEATURES => { flag_key.to_sym => flag } })

            threads = []
            errors = []

            # Writer threads
            5.times do |i|
              threads << Thread.new do
                begin
                  10.times do |j|
                    new_flag = flag.merge(key: "flag-#{i}-#{j}", version: j + 1)
                    subject.apply_delta({ FEATURES => { "flag-#{i}-#{j}".to_sym => new_flag } })
                  end
                rescue => e
                  errors << e
                end
              end
            end

            # Reader threads
            5.times do
              threads << Thread.new do
                begin
                  20.times do
                    subject.get(FEATURES, flag_key)
                    subject.all(FEATURES)
                  end
                rescue => e
                  errors << e
                end
              end
            end

            threads.each(&:join)
            expect(errors).to be_empty
          end
        end
      end
    end
  end
end
