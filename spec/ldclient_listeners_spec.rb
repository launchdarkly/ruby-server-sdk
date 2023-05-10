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
        store = MockBigSegmentStore.new
        store.setup_metadata(Time.now)
        big_segments_config = BigSegmentsConfig.new(
          store: store,
          status_poll_interval: 0.01
        )
        with_client(test_config(big_segments: big_segments_config)) do |client|
          status1 = client.big_segment_store_status_provider.status
          expect(status1.available).to be(true)
          expect(status1.stale).to be(false)

          statuses = Queue.new
          observer = SimpleObserver.adding_to_queue(statuses)
          client.big_segment_store_status_provider.add_observer(observer)

          store.setup_metadata_error(StandardError.new("sorry"))

          status2 = statuses.pop
          expect(status2.available).to be(false)
          expect(status2.stale).to be(false)

          expect(client.big_segment_store_status_provider.status).to eq(status2)
        end
      end
    end
  end
end
