require "spec_helper"
require 'ostruct'

describe LaunchDarkly::InMemoryFeatureStore do
  subject { LaunchDarkly::InMemoryFeatureStore }

  include LaunchDarkly
  
  let(:store) { subject.new }
  let(:key) { :asdf }
  let(:feature) { { key: "asdf", value: "qwer", version: 0 } }

  describe '#all' do
    it "will get all keys" do
      store.upsert(LaunchDarkly::FEATURES, feature)
      data = store.all(LaunchDarkly::FEATURES)
      expect(data).to eq(key => feature)
    end
    it "will not get deleted keys" do
      store.upsert(LaunchDarkly::FEATURES, feature)
      store.delete(LaunchDarkly::FEATURES, key, 1)
      data = store.all(LaunchDarkly::FEATURES)
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
    let(:put_message) { OpenStruct.new({data: '{"data":{"flags":{"asdf": {"key": "asdf"}},"segments":{"segkey": {"key": "segkey"}}}}'}) }
    let(:patch_flag_message) { OpenStruct.new({data: '{"path": "/flags/key", "data": {"key": "asdf", "version": 1}}'}) }
    let(:patch_seg_message) { OpenStruct.new({data: '{"path": "/segments/key", "data": {"key": "asdf", "version": 1}}'}) }
    let(:delete_flag_message) { OpenStruct.new({data: '{"path": "/flags/key", "version": 2}'}) }
    let(:delete_seg_message) { OpenStruct.new({data: '{"path": "/segments/key", "version": 2}'}) }
    it "will accept PUT methods" do
      processor.send(:process_message, put_message, LaunchDarkly::PUT)
      expect(config.feature_store.get(LaunchDarkly::FEATURES, "asdf")).to eq(key: "asdf")
      expect(config.feature_store.get(LaunchDarkly::SEGMENTS, "segkey")).to eq(key: "segkey")
    end
    it "will accept PATCH methods for flags" do
      processor.send(:process_message, patch_flag_message, LaunchDarkly::PATCH)
      expect(config.feature_store.get(LaunchDarkly::FEATURES, "asdf")).to eq(key: "asdf", version: 1)
    end
    it "will accept PATCH methods for segments" do
      processor.send(:process_message, patch_seg_message, LaunchDarkly::PATCH)
      expect(config.feature_store.get(LaunchDarkly::SEGMENTS, "asdf")).to eq(key: "asdf", version: 1)
    end
    it "will accept DELETE methods for flags" do
      processor.send(:process_message, patch_flag_message, LaunchDarkly::PATCH)
      processor.send(:process_message, delete_flag_message, LaunchDarkly::DELETE)
      expect(config.feature_store.get(LaunchDarkly::FEATURES, "key")).to eq(nil)
    end
    it "will accept DELETE methods for segments" do
      processor.send(:process_message, patch_seg_message, LaunchDarkly::PATCH)
      processor.send(:process_message, delete_seg_message, LaunchDarkly::DELETE)
      expect(config.feature_store.get(LaunchDarkly::SEGMENTS, "key")).to eq(nil)
    end
    it "will log a warning if the method is not recognized" do
      expect(processor.instance_variable_get(:@config).logger).to receive :warn
      processor.send(:process_message, put_message, "get")
    end
  end
end

