require 'spec_helper'

describe LaunchDarkly::InMemoryFeatureStore do
  subject { LaunchDarkly::InMemoryFeatureStore }
end

describe LaunchDarkly::StreamProcessor do
  subject { LaunchDarkly::StreamProcessor }
  let(:config) { LaunchDarkly::Config.new }
  let(:processor) { LaunchDarkly::StreamProcessor.new('api_key', config) }
  describe '#start' do
    it 'will check if the reactor has started' do
      expect(processor).to receive(:start_reactor).and_return false
      expect(EM).to_not receive(:defer)
      processor.start
    end
    it 'will check if the stream processor has already started' do
      expect(processor).to receive(:start_reactor).and_return true
      processor.instance_variable_get(:@started).make_true
      expect(EM).to_not receive(:defer)
      processor.start
    end
    it 'will boot the stream processor' do
      expect(processor).to receive(:start_reactor).and_return true
      expect(EM).to receive(:defer)
      processor.start
    end
  end

  describe '#boot_event_manager' do
    # TODO
  end

  describe '#process_message' do
    let(:put_message) { '{"key": {"value": "asdf"}}' }
    let(:patch_message) { '{"path": "akey", "data": {"value": "asdf", "version": 1}}' }
    let(:delete_message) { '{"path": "akey", "version": 2}' }
    it 'will accept PUT methods' do
      processor.send(:process_message, put_message, LaunchDarkly::PUT)
      expect(processor.instance_variable_get(:@store).get("key")).to eq({value: 'asdf'})
    end
    it 'will accept PATCH methods' do
      processor.send(:process_message, patch_message, LaunchDarkly::PATCH)
      expect(processor.instance_variable_get(:@store).get("key")).to eq({value: 'asdf', version: 1})
    end
    it 'will accept DELETE methods' do
      processor.send(:process_message, patch_message, LaunchDarkly::PATCH)
      processor.send(:process_message, delete_message, LaunchDarkly::DELETE)
      expect(processor.instance_variable_get(:@store).get("key")).to eq(nil)
    end
    it 'will log an error if the method is not recognized' do
      expect(processor.instance_variable_get(:@config).logger).to receive :error
      processor.send(:process_message, put_message, 'get')
    end
  end
end
