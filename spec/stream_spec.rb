require "spec_helper"
require 'ostruct'

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
  let(:requestor) { LaunchDarkly::Requestor.new("sdk_key", config)}
  let(:processor) { subject.new("sdk_key", config, requestor) }

  describe '#process_message' do
    let(:put_message) { OpenStruct.new({data: '{"flags":{"key": {"value": "asdf"}},"segments":{"segkey": {"value": "asdf"}}}'}) }
    let(:patch_flag_message) { OpenStruct.new({data: '{"path": "/flags/key", "data": {"value": "asdf", "version": 1}}'}) }
    let(:patch_seg_message) { OpenStruct.new({data: '{"path": "/segments/key", "data": {"value": "asdf", "version": 1}}'}) }
    let(:delete_flag_message) { OpenStruct.new({data: '{"path": "/flags/key", "version": 2}'}) }
    let(:delete_seg_message) { OpenStruct.new({data: '{"path": "/segments/key", "version": 2}'}) }
    it "will accept PUT methods" do
      processor.send(:process_message, put_message, LaunchDarkly::PUT)
      expect(config.feature_store.get("key")).to eq(value: "asdf")
      expect(config.segment_store.get("segkey")).to eq(value: "asdf")
    end
    it "will accept PATCH methods for flags" do
      processor.send(:process_message, patch_flag_message, LaunchDarkly::PATCH)
      expect(config.feature_store.get("key")).to eq(value: "asdf", version: 1)
    end
    it "will accept PATCH methods for segments" do
      processor.send(:process_message, patch_seg_message, LaunchDarkly::PATCH)
      expect(config.segment_store.get("key")).to eq(value: "asdf", version: 1)
    end
    it "will accept DELETE methods for flags" do
      processor.send(:process_message, patch_flag_message, LaunchDarkly::PATCH)
      processor.send(:process_message, delete_flag_message, LaunchDarkly::DELETE)
      expect(config.feature_store.get("key")).to eq(nil)
    end
    it "will accept DELETE methods for segments" do
      processor.send(:process_message, patch_seg_message, LaunchDarkly::PATCH)
      processor.send(:process_message, delete_seg_message, LaunchDarkly::DELETE)
      expect(config.segment_store.get("key")).to eq(nil)
    end
    it "will log a warning if the method is not recognized" do
      expect(processor.instance_variable_get(:@config).logger).to receive :warn
      processor.send(:process_message, put_message, "get")
    end
  end
end

