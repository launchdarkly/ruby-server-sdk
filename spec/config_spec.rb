require "spec_helper"

describe LaunchDarkly::Config do
  subject { LaunchDarkly::Config }
  describe ".initialize" do
    it "can be initialized with default settings" do
      expect(subject).to receive(:default_capacity).and_return 1234
      expect(subject.new.capacity).to eq 1234
    end
    it "accepts custom arguments" do
      expect(subject).to_not receive(:default_capacity)
      expect(subject.new(capacity: 50).capacity).to eq 50
    end
    it "will chomp base_url and stream_uri" do
      uri = "https://test.launchdarkly.com"
      config = subject.new(base_uri: uri + "/")
      expect(config.base_uri).to eq uri
    end
  end
  describe "@base_uri" do
    it "can be read" do
      expect(subject.new.base_uri).to eq subject.default_base_uri
    end
  end
  describe "@events_uri" do
    it "can be read" do
      expect(subject.new.events_uri).to eq subject.default_events_uri
    end
  end
  describe "@stream_uri" do
    it "can be read" do
      expect(subject.new.stream_uri).to eq subject.default_stream_uri
    end
  end
  describe ".default_cache_store" do
    it "uses Rails cache if it is available" do
      rails = instance_double("Rails", cache: :cache)
      stub_const("Rails", rails)
      expect(subject.default_cache_store).to eq :cache
    end
    it "uses memory store if Rails is not available" do
      expect(subject.default_cache_store).to be_an_instance_of LaunchDarkly::ThreadSafeMemoryStore
    end
  end
  describe ".default_logger" do
    it "uses Rails logger if it is available" do
      rails = instance_double("Rails", logger: :logger)
      stub_const("Rails", rails)
      expect(subject.default_logger).to eq :logger
    end
    it "Uses logger if Rails is not available" do
      expect(subject.default_logger).to be_an_instance_of Logger
    end
  end
end
