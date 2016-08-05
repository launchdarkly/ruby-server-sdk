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
    let(:put_message) { OpenStruct.new({data: '{"key": {"value": "asdf"}}'}) }
    let(:patch_message) { OpenStruct.new({data: '{"path": "akey", "data": {"value": "asdf", "version": 1}}'}) }
    let(:delete_message) { OpenStruct.new({data: '{"path": "akey", "version": 2}'}) }
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
end

