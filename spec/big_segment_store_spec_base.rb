require "spec_helper"

# Reusable test logic for testing BigSegmentStore implementations.
#
# Usage:
#
# class MyStoreTester
#   def initialize(options)
#     @options = options
#   end
#   def create_big_segment_store
#     MyBigSegmentStoreImplClass.new(@options)
#   end
#   def clear_data
#     # clear any existing data from the database, taking @options[:prefix] into account
#   end
#   def set_big_segments_metadata(metadata)
#     # write the metadata to the database, taking @options[:prefix] into account
#   end
#   def set_big_segments(context_hash, includes, excludes)
#     # update the include and exclude lists for a context, taking @options[:prefix] into account
#   end
# end
#
# describe "my big segment store" do
#   include_examples "big_segment_store", MyStoreTester
# end

shared_examples "big_segment_store" do |store_tester_class|
  base_options = { logger: $null_logger }

  prefix_test_groups = [
    ["with default prefix", {}],
    ["with specified prefix", { prefix: "testprefix" }],
  ]
  prefix_test_groups.each do |subgroup_description, prefix_options|
    context(subgroup_description) do
      # The following tests are done for each permutation of (default prefix/specified prefix)

      let(:store_tester) { store_tester_class.new(prefix_options.merge(base_options)) }
      let(:fake_context_hash) { "contexthash" }

      def with_empty_store
        store_tester.clear_data
        ensure_stop(store_tester.create_big_segment_store) do |store|
          yield store
        end
      end

      context "get_metadata" do
        it "valid value" do
          expected_timestamp = 1234567890
          with_empty_store do |store|
            store_tester.set_big_segments_metadata(LaunchDarkly::Interfaces::BigSegmentStoreMetadata.new(expected_timestamp))

            actual = store.get_metadata

            expect(actual).not_to be nil
            expect(actual.last_up_to_date).to eq(expected_timestamp)
          end
        end

        it "no value" do
          with_empty_store do |store|
            actual = store.get_metadata

            expect(actual).not_to be nil
            expect(actual.last_up_to_date).to be nil
          end
        end
      end

      context "get_membership" do
        it "not found" do
          with_empty_store do |store|
            membership = store.get_membership(fake_context_hash)
            membership = {} if membership.nil?

            expect(membership).to eq({})
          end
        end

        it "includes only" do
          with_empty_store do |store|
            store_tester.set_big_segments(fake_context_hash, ["key1", "key2"], [])

            membership = store.get_membership(fake_context_hash)
            expect(membership).to eq({ "key1" => true, "key2" => true })
          end
        end

        it "excludes only" do
          with_empty_store do |store|
            store_tester.set_big_segments(fake_context_hash, [], ["key1", "key2"])

            membership = store.get_membership(fake_context_hash)
            expect(membership).to eq({ "key1" => false, "key2" => false })
          end
        end

        it "includes and excludes" do
          with_empty_store do |store|
            store_tester.set_big_segments(fake_context_hash, ["key1", "key2"], ["key2", "key3"])

            membership = store.get_membership(fake_context_hash)
            expect(membership).to eq({ "key1" => true, "key2" => true, "key3" => false }) # include of key2 overrides exclude
          end
        end
      end
    end
  end
end
