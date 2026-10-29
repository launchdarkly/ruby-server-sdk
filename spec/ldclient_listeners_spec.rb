require "mock_components"
require "spec_helper"

module LaunchDarkly
  describe "LDClient event listeners/observers" do
    context "big_segment_store_status_provider" do
      it "returns unavailable status when not configured" do
        with_client(test_config) do |client|
          status = client.big_segment_store_status_provider.status
          expect(status.available).to be(false)
          expect(status.stale).to be(false)
        end
      end

      it "sends status updates" do
        store = GatedBigSegmentStore.new
        store.queue_metadata(Time.now)
        big_segments_config = BigSegmentsConfig.new(
          store: store,
          status_poll_interval: 0.01
        )
        with_client(test_config(big_segments: big_segments_config)) do |client|
          status1 = client.big_segment_store_status_provider.status
          expect(status1.available).to be(true)
          expect(status1.stale).to be(false)

          # Status reads after the first come from the cache, so the second query comes from the
          # poller. Observers have been notified of the first status by the time it starts, so the
          # observer added below sees only later changes.
          expect(store.wait_for_queries(2)).to be(true)

          statuses = Queue.new
          observer = SimpleObserver.adding_to_queue(statuses)
          client.big_segment_store_status_provider.add_observer(observer)

          # Fail the waiting query, then wait for the poller to start the next one. It has notified
          # observers of the failure by then.
          store.queue_metadata_error(StandardError.new("sorry"))
          expect(store.wait_for_queries(3)).to be(true)

          # The observer should have received one status, reporting the store as unavailable.
          expect(statuses.size).to eq(1)
          status2 = statuses.pop
          expect(status2.available).to be(false)
          expect(status2.stale).to be(false)

          expect(client.big_segment_store_status_provider.status).to eq(status2)
        ensure
          store.release
        end
      end
    end
  end
end
