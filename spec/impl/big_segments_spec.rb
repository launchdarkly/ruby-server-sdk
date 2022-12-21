require "ldclient-rb/config"
require "ldclient-rb/impl/big_segments"

require "concurrent/atomics"

require "mock_components"
require "spec_helper"

module LaunchDarkly
  module Impl
    describe BigSegmentStoreManager do
      subject { BigSegmentStoreManager }

      let(:context_key) { 'contextkey' }
      let(:context_hash) { subject.hash_for_context_key(context_key) }
      let(:null_logger) { double.as_null_object }

      def always_up_to_date
        Interfaces::BigSegmentStoreMetadata.new(Util.current_time_millis)
      end

      def always_stale
        Interfaces::BigSegmentStoreMetadata.new(0)
      end

      def with_manager(config)
        manager = subject.new(config, null_logger)
        begin
          yield manager
        ensure
          manager.stop
        end
      end

      context "membership query" do
        it "with uncached result and healthy status" do
          expected_membership = { 'key1' => true, 'key2' => true }
          store = double
          expect(store).to receive(:get_metadata).at_least(:once).and_return(always_up_to_date)
          expect(store).to receive(:get_membership).with(context_hash).and_return(expected_membership)
          allow(store).to receive(:stop)

          with_manager(BigSegmentsConfig.new(store: store)) do |m|
            expected_result = BigSegmentMembershipResult.new(expected_membership, BigSegmentsStatus::HEALTHY)
            expect(m.get_context_membership(context_key)).to eq(expected_result)
          end
        end

        it "with cached result and healthy status" do
          expected_membership = { 'key1' => true, 'key2' => true }
          store = double
          expect(store).to receive(:get_metadata).at_least(:once).and_return(always_up_to_date)
          expect(store).to receive(:get_membership).with(context_hash).once.and_return(expected_membership)
          # the ".once" on this mock expectation is what verifies that the cache is working; there should only be one query
          allow(store).to receive(:stop)

          with_manager(BigSegmentsConfig.new(store: store)) do |m|
            expected_result = BigSegmentMembershipResult.new(expected_membership, BigSegmentsStatus::HEALTHY)
            expect(m.get_context_membership(context_key)).to eq(expected_result)
            expect(m.get_context_membership(context_key)).to eq(expected_result)
          end
        end

        it "can cache a nil result" do
          store = double
          expect(store).to receive(:get_metadata).at_least(:once).and_return(always_up_to_date)
          expect(store).to receive(:get_membership).with(context_hash).once.and_return(nil)
          # the ".once" on this mock expectation is what verifies that the cache is working; there should only be one query
          allow(store).to receive(:stop)

          with_manager(BigSegmentsConfig.new(store: store)) do |m|
            expected_result = BigSegmentMembershipResult.new({}, BigSegmentsStatus::HEALTHY)
            expect(m.get_context_membership(context_key)).to eq(expected_result)
            expect(m.get_context_membership(context_key)).to eq(expected_result)
          end
        end

        it "cache can expire" do
          expected_membership = { 'key1' => true, 'key2' => true }
          store = double
          expect(store).to receive(:get_metadata).at_least(:once).and_return(always_up_to_date)
          expect(store).to receive(:get_membership).with(context_hash).twice.and_return(expected_membership)
          # the ".twice" on this mock expectation is what verifies that the cached result expired
          allow(store).to receive(:stop)

          with_manager(BigSegmentsConfig.new(store: store, context_cache_time: 0.01)) do |m|
            expected_result = BigSegmentMembershipResult.new(expected_membership, BigSegmentsStatus::HEALTHY)
            expect(m.get_context_membership(context_key)).to eq(expected_result)
            sleep(0.1)
            expect(m.get_context_membership(context_key)).to eq(expected_result)
          end
        end

        it "with stale status" do
          expected_membership = { 'key1' => true, 'key2' => true }
          store = double
          expect(store).to receive(:get_metadata).at_least(:once).and_return(always_stale)
          expect(store).to receive(:get_membership).with(context_hash).and_return(expected_membership)
          allow(store).to receive(:stop)

          with_manager(BigSegmentsConfig.new(store: store)) do |m|
            expected_result = BigSegmentMembershipResult.new(expected_membership, BigSegmentsStatus::STALE)
            expect(m.get_context_membership(context_key)).to eq(expected_result)
          end
        end

        it "with stale status due to no store metadata" do
          expected_membership = { 'key1' => true, 'key2' => true }
          store = double
          expect(store).to receive(:get_metadata).at_least(:once).and_return(nil)
          expect(store).to receive(:get_membership).with(context_hash).and_return(expected_membership)
          allow(store).to receive(:stop)

          with_manager(BigSegmentsConfig.new(store: store)) do |m|
            expected_result = BigSegmentMembershipResult.new(expected_membership, BigSegmentsStatus::STALE)
            expect(m.get_context_membership(context_key)).to eq(expected_result)
          end
        end

        it "least recent context is evicted from cache" do
          context_key_1, context_key_2, context_key_3 = 'contextkey1', 'contextkey2', 'contextkey3'
          context_hash_1, context_hash_2, context_hash_3 = subject.hash_for_context_key(context_key_1),
            subject.hash_for_context_key(context_key_2), subject.hash_for_context_key(context_key_3)
          memberships = {
            context_hash_1 => { 'seg1': true },
            context_hash_2 => { 'seg2': true },
            context_hash_3 => { 'seg3': true },
          }
          queries_contexts = []
          store = double
          expect(store).to receive(:get_metadata).at_least(:once).and_return(always_up_to_date)
          expect(store).to receive(:get_membership).exactly(4).times do |key|
            queries_contexts << key
            memberships[key]
          end
          allow(store).to receive(:stop)

          with_manager(BigSegmentsConfig.new(store: store, context_cache_size: 2)) do |m|
            result1 = m.get_context_membership(context_key_1)
            result2 = m.get_context_membership(context_key_2)
            result3 = m.get_context_membership(context_key_3)
            expect(result1).to eq(BigSegmentMembershipResult.new(memberships[context_hash_1], BigSegmentsStatus::HEALTHY))
            expect(result2).to eq(BigSegmentMembershipResult.new(memberships[context_hash_2], BigSegmentsStatus::HEALTHY))
            expect(result3).to eq(BigSegmentMembershipResult.new(memberships[context_hash_3], BigSegmentsStatus::HEALTHY))

            expect(queries_contexts).to eq([context_hash_1, context_hash_2, context_hash_3])

            # Since the capacity is only 2 and context_key_1 was the least recently used, that key should be
            # evicted by the context_key_3 query. Now only context_key_2 and context_key_3 are in the cache, and
            # querying them again should not cause a new query to the store.

            result2a = m.get_context_membership(context_key_2)
            result3a = m.get_context_membership(context_key_3)
            expect(result2a).to eq(result2)
            expect(result3a).to eq(result3)

            expect(queries_contexts).to eq([context_hash_1, context_hash_2, context_hash_3])

            result1a = m.get_context_membership(context_key_1)
            expect(result1a).to eq(result1)

            expect(queries_contexts).to eq([context_hash_1, context_hash_2, context_hash_3, context_hash_1])
          end
        end
      end

      context "status polling" do
        it "detects store unavailability" do
          store = double
          should_fail = Concurrent::AtomicBoolean.new(false)
          expect(store).to receive(:get_metadata).at_least(:once) do
            throw "sorry" if should_fail.value
            always_up_to_date
          end
          allow(store).to receive(:stop)

          statuses = Queue.new
          with_manager(BigSegmentsConfig.new(store: store, status_poll_interval: 0.01)) do |m|
            m.status_provider.add_observer(SimpleObserver.new(->(value) { statuses << value }))

            status1 = statuses.pop()
            expect(status1.available).to be(true)

            should_fail.make_true

            status2 = statuses.pop()
            expect(status2.available).to be(false)

            should_fail.make_false

            status3 = statuses.pop()
            expect(status3.available).to be(true)
          end
        end

        it "detects stale status" do
          store = double
          should_be_stale = Concurrent::AtomicBoolean.new(false)
          expect(store).to receive(:get_metadata).at_least(:once) do
            should_be_stale.value ? always_stale : always_up_to_date
          end
          allow(store).to receive(:stop)

          statuses = Queue.new
          with_manager(BigSegmentsConfig.new(store: store, status_poll_interval: 0.01)) do |m|
            m.status_provider.add_observer(SimpleObserver.new(->(value) { statuses << value }))

            status1 = statuses.pop()
            expect(status1.stale).to be(false)

            should_be_stale.make_true

            status2 = statuses.pop()
            expect(status2.stale).to be(true)

            should_be_stale.make_false

            status3 = statuses.pop()
            expect(status3.stale).to be(false)
          end
        end
      end
    end
  end
end
