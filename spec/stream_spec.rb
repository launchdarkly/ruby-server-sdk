require "ld-eventsource"
require "model_builders"
require "spec_helper"

describe LaunchDarkly::StreamProcessor do
  subject { LaunchDarkly::StreamProcessor }
  let(:executor) { SynchronousExecutor.new }
  let(:status_broadcaster) { LaunchDarkly::Impl::Broadcaster.new(executor, $null_log) }
  let(:flag_change_broadcaster) { LaunchDarkly::Impl::Broadcaster.new(executor, $null_log) }
  let(:config) {
    config = LaunchDarkly::Config.new
    config.data_source_update_sink = LaunchDarkly::Impl::DataSource::UpdateSink.new(config.feature_store, status_broadcaster, flag_change_broadcaster)
    config.data_source_update_sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
    config
  }
  let(:processor) { subject.new("sdk_key", config) }

  describe '#process_message' do
    let(:put_message) { SSE::StreamEvent.new(:put, '{"data":{"flags":{"asdf": {"key": "asdf"}},"segments":{"segkey": {"key": "segkey"}}}}') }
    let(:patch_flag_message) { SSE::StreamEvent.new(:patch, '{"path": "/flags/key", "data": {"key": "asdf", "version": 1}}') }
    let(:patch_seg_message) { SSE::StreamEvent.new(:patch, '{"path": "/segments/key", "data": {"key": "asdf", "version": 1}}') }
    let(:delete_flag_message) { SSE::StreamEvent.new(:delete, '{"path": "/flags/key", "version": 2}') }
    let(:delete_seg_message) { SSE::StreamEvent.new(:delete, '{"path": "/segments/key", "version": 2}') }
    let(:invalid_message) { SSE::StreamEvent.new(:put, '{Hi there}') }

    it "will accept PUT methods" do
      processor.send(:process_message, put_message)
      expect(config.feature_store.get(LaunchDarkly::FEATURES, "asdf")).to eq(Flags.from_hash(key: "asdf"))
      expect(config.feature_store.get(LaunchDarkly::SEGMENTS, "segkey")).to eq(Segments.from_hash(key: "segkey"))
    end
    it "will accept PATCH methods for flags" do
      processor.send(:process_message, patch_flag_message)
      expect(config.feature_store.get(LaunchDarkly::FEATURES, "asdf")).to eq(Flags.from_hash(key: "asdf", version: 1))
    end
    it "will accept PATCH methods for segments" do
      processor.send(:process_message, patch_seg_message)
      expect(config.feature_store.get(LaunchDarkly::SEGMENTS, "asdf")).to eq(Segments.from_hash(key: "asdf", version: 1))
    end
    it "will accept DELETE methods for flags" do
      processor.send(:process_message, patch_flag_message)
      processor.send(:process_message, delete_flag_message)
      expect(config.feature_store.get(LaunchDarkly::FEATURES, "key")).to eq(nil)
    end
    it "will accept DELETE methods for segments" do
      processor.send(:process_message, patch_seg_message)
      processor.send(:process_message, delete_seg_message)
      expect(config.feature_store.get(LaunchDarkly::SEGMENTS, "key")).to eq(nil)
    end
    it "will log a warning if the method is not recognized" do
      expect(processor.instance_variable_get(:@config).logger).to receive :warn
      processor.send(:process_message, SSE::StreamEvent.new(type: :get, data: "", id: nil))
    end
    it "status listener will trigger error when JSON is invalid" do
      listener = ListenerSpy.new
      status_broadcaster.add_listener(listener)

      begin
        processor.send(:process_message, invalid_message)
      rescue
      end

      expect(listener.statuses.count).to eq(2)
      expect(listener.statuses[1].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
      expect(listener.statuses[1].last_error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::INVALID_DATA)
    end
  end
end
