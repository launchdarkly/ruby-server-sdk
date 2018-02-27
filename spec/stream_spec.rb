require "spec_helper"
require 'ostruct'

describe LaunchDarkly::StreamProcessor do
  subject { LaunchDarkly::StreamProcessor }
  let(:config) { LaunchDarkly::Config.new }
  let(:requestor) { double() }
  let(:processor) { subject.new("sdk_key", config, requestor) }

  describe '#process_message' do
    let(:put_message) { OpenStruct.new({data: '{"data":{"flags":{"asdf": {"key": "asdf"}},"segments":{"segkey": {"key": "segkey"}}}}'}) }
    let(:patch_flag_message) { OpenStruct.new({data: '{"path": "/flags/key", "data": {"key": "asdf", "version": 1}}'}) }
    let(:patch_seg_message) { OpenStruct.new({data: '{"path": "/segments/key", "data": {"key": "asdf", "version": 1}}'}) }
    let(:delete_flag_message) { OpenStruct.new({data: '{"path": "/flags/key", "version": 2}'}) }
    let(:delete_seg_message) { OpenStruct.new({data: '{"path": "/segments/key", "version": 2}'}) }
    let(:indirect_patch_flag_message) { OpenStruct.new({data: "/flags/key"}) }
    let(:indirect_patch_segment_message) { OpenStruct.new({data: "/segments/key"}) }

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
    it "will accept INDIRECT PATCH method for flags" do
      flag = { key: 'key', version: 1 }
      allow(requestor).to receive(:request_flag).with(flag[:key]).and_return(flag)
      processor.send(:process_message, indirect_patch_flag_message, LaunchDarkly::INDIRECT_PATCH);
      expect(config.feature_store.get(LaunchDarkly::FEATURES, flag[:key])).to eq(flag)
    end
    it "will accept INDIRECT PATCH method for segments" do
      segment = { key: 'key', version: 1 }
      allow(requestor).to receive(:request_segment).with(segment[:key]).and_return(segment)
      processor.send(:process_message, indirect_patch_segment_message, LaunchDarkly::INDIRECT_PATCH);
      expect(config.feature_store.get(LaunchDarkly::SEGMENTS, segment[:key])).to eq(segment)
    end
    it "will log a warning if the method is not recognized" do
      expect(processor.instance_variable_get(:@config).logger).to receive :warn
      processor.send(:process_message, put_message, "get")
    end
  end
end

