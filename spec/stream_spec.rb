require "spec_helper"

describe LaunchDarkly::InMemoryFeatureStore do
  subject { LaunchDarkly::InMemoryFeatureStore }
  let(:store) { subject.new }
  let(:key) { :asdf }
  let(:feature) { { value: "qwer", version: 0 } }

  describe '#all' do
    it "will get all keys" do
      store.upsert(key, feature)
      data = store.all
      expect(data).to eq(key => feature)
    end
    it "will not get deleted keys" do
      store.upsert(key, feature)
      store.delete(key, 1)
      data = store.all
      expect(data).to eq({})
    end
  end

  describe '#initialized?' do
    it "will return whether the store has been initialized" do
      expect(store.initialized?).to eq false
      store.init(key => feature)
      expect(store.initialized?).to eq true
    end
  end
end

describe LaunchDarkly::StreamProcessor do
  subject { LaunchDarkly::StreamProcessor }
  let(:config) { LaunchDarkly::Config.new }
  let(:processor) { subject.new("api_key", config) }
  describe '#start' do
    it "will check if the reactor has started" do
      expect(processor).to receive(:start_reactor).and_return false
      expect(EM).to_not receive(:defer)
      processor.start
    end
    it "will check if the stream processor has already started" do
      expect(processor).to receive(:start_reactor).and_return true
      processor.instance_variable_get(:@started).make_true
      expect(EM).to_not receive(:defer)
      processor.start
    end
    it "will boot the stream processor" do
      expect(processor).to receive(:start_reactor).and_return true
      expect(EM).to receive(:defer)
      processor.start
    end
  end

  describe '#boot_event_manager' do
    let(:message) { "asdf" }
    before do
      processor.instance_variable_get(:@config).instance_variable_set(:@stream_uri, "http://example.com/streaming")
      expect_any_instance_of(EM::EventSource).to receive(:start)
      source = processor.send(:boot_event_manager)
      @req = source.instance_variable_get "@req"
      # It seems  testing EventManager is hard/impossible
    end
    it "will start" do
    end
    xit "will process put messages" do
      expect(processor).to receive(:process_message).with(message, LaunchDarkly::PUT)
      @req.stream_data("data: #{message}\nevent:#{LaunchDarkly::PUT}\n")
    end
    xit "will process patch messages" do
      expect(processor).to receive(:process_message).with(message, LaunchDarkly::PATCH)
    end
    xit "will process delete messages" do
      expect(processor).to receive(:process_message).with(message, LaunchDarkly::DELETE)
    end
    xit "will process errors" do
      expect(processor).to receive(:set_disconnected)
    end
  end

  describe '#process_message' do
    let(:put_message) { '{"key": {"value": "asdf"}}' }
    let(:patch_message) { '{"path": "akey", "data": {"value": "asdf", "version": 1}}' }
    let(:delete_message) { '{"path": "akey", "version": 2}' }
    it "will accept PUT methods" do
      processor.send(:process_message, put_message, LaunchDarkly::PUT)
      expect(processor.instance_variable_get(:@store).get("key")).to eq(value: "asdf")
    end
    it "will accept PATCH methods" do
      processor.send(:process_message, patch_message, LaunchDarkly::PATCH)
      expect(processor.instance_variable_get(:@store).get("key")).to eq(value: "asdf", version: 1)
    end
    it "will accept DELETE methods" do
      processor.send(:process_message, patch_message, LaunchDarkly::PATCH)
      processor.send(:process_message, delete_message, LaunchDarkly::DELETE)
      expect(processor.instance_variable_get(:@store).get("key")).to eq(nil)
    end
    it "will log an error if the method is not recognized" do
      expect(processor.instance_variable_get(:@config).logger).to receive :error
      processor.send(:process_message, put_message, "get")
    end
  end

  describe '#should_fallback_update' do
    it "will return true if the stream is disconnected for more than 120 seconds" do
      processor.send(:set_disconnected)
      future_time = Time.now + 200
      expect(Time).to receive(:now).and_return(future_time)
      value = processor.send(:should_fallback_update)
      expect(value).to eq true
    end
    it "will return false otherwise" do
      processor.send(:set_connected)
      value = processor.send(:should_fallback_update)
      expect(value).to eq false
    end
  end
end
