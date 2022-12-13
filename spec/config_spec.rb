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
  describe ".poll_interval" do
    it "can be set to greater than the default" do
      expect(subject.new(poll_interval: 31).poll_interval).to eq 31
    end
    it "cannot be set to less than the default" do
      expect(subject.new(poll_interval: 29).poll_interval).to eq 30
    end
  end

  describe ".application" do
    it "can be set and read" do
      app = { id: "my-id", version: "abcdef" }
      expect(subject.new(application: app).application).to eq app
    end

    it "can handle non-string values" do
      expect(subject.new(application: { id: 1, version: 2 }).application).to eq ({ id: "1", version: "2" })
    end

    it "will ignore invalid keys" do
      expect(subject.new(application: { invalid: 1, hashKey: 2 }).application).to eq ({ id: "", version: "" })
    end

    it "will drop invalid values" do
      [" ", "@", ":", "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-a"].each do |value|
        expect(subject.new(logger: $null_log, application: { id: value, version: value }).application).to eq ({ id: "", version: "" })
      end
    end

    it "will generate correct header tag value" do
      [
        { :id => "id", :version => "version", :expected => "application-id/id application-version/version" },
        { :id => "id", :version => "", :expected => "application-id/id" },
        { :id => "", :version => "version", :expected => "application-version/version" },
        { :id => "", :version => "", :expected => "" },
      ].each do |test_case|
        config = subject.new(application: { id: test_case[:id], version: test_case[:version] })
        expect(LaunchDarkly::Impl::Util.application_header_value(config.application)).to eq test_case[:expected]
      end
    end
  end

  describe "context and user aliases" do
    it "default values are aliased correctly" do
      expect(LaunchDarkly::Config.default_context_keys_capacity).to eq LaunchDarkly::Config.default_user_keys_capacity
      expect(LaunchDarkly::Config.default_context_keys_flush_interval).to eq LaunchDarkly::Config.default_user_keys_flush_interval
    end

    it "context options are reflected in user options" do
      config = subject.new(context_keys_capacity: 50, context_keys_flush_interval: 25)
      expect(config.context_keys_capacity).to eq config.user_keys_capacity
      expect(config.context_keys_flush_interval).to eq config.user_keys_flush_interval
    end

    it "context options can be set by user options" do
      config = subject.new(user_keys_capacity: 50, user_keys_flush_interval: 25)
      expect(config.context_keys_capacity).to eq config.user_keys_capacity
      expect(config.context_keys_flush_interval).to eq config.user_keys_flush_interval
    end

    it "context options take precedence" do
      config = subject.new(context_keys_capacity: 100, user_keys_capacity: 50, context_keys_flush_interval: 100, user_keys_flush_interval: 50)

      expect(config.context_keys_capacity).to eq 100
      expect(config.context_keys_flush_interval).to eq 100
    end
  end
end
