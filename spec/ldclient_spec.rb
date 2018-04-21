require "spec_helper"


describe LaunchDarkly::LDClient do
  subject { LaunchDarkly::LDClient }
  let(:offline_config) { LaunchDarkly::Config.new({offline: true}) }
  let(:offline_client) do
    subject.new("secret", offline_config)
  end
  let(:update_processor) { NullUpdateProcessor.new }
  let(:config) { LaunchDarkly::Config.new({send_events: false, update_processor: update_processor}) }
  let(:client) do
    subject.new("secret", config)
  end
  let(:feature) do
    data = File.read(File.join("spec", "fixtures", "feature.json"))
    JSON.parse(data, symbolize_names: true)
  end
  let(:user) do
    data = File.read(File.join("spec", "fixtures", "user.json"))
    JSON.parse(data, symbolize_names: true)
  end
  let(:numeric_key_user) do
    data = File.read(File.join("spec", "fixtures", "numeric_key_user.json"))
    JSON.parse(data, symbolize_names: true)
  end
  let(:sanitized_numeric_key_user) do
    data = File.read(File.join("spec", "fixtures", "sanitized_numeric_key_user.json"))
    JSON.parse(data, symbolize_names: true)
  end

  def event_processor
    client.instance_variable_get(:@event_processor)
  end

  describe '#variation' do
    it "will return the default value if the client is offline" do
      result = offline_client.variation("doesntmatter", user, "default")
      expect(result).to eq "default"
    end

    it "queues a feature request event for an unknown feature" do
      expect(event_processor).to receive(:add_event).with(hash_including(
        kind: "feature", key: "badkey", user: user, value: "default", default: "default"
      ))
      client.variation("badkey", user, "default")
    end

    it "queues a feature request event for an existing feature" do
      config.feature_store.init({ LaunchDarkly::FEATURES => {} })
      config.feature_store.upsert(LaunchDarkly::FEATURES, feature)
      expect(event_processor).to receive(:add_event).with(hash_including(
        kind: "feature",
        key: feature[:key],
        version: feature[:version],
        user: user,
        variation: 0,
        value: true,
        default: "default",
        trackEvents: false,
        debugEventsUntilDate: nil
      ))
      client.variation(feature[:key], user, "default")
    end
  end

  describe '#secure_mode_hash' do
    it "will return the expected value for a known message and secret" do
      result = client.secure_mode_hash({key: :Message})
      expect(result).to eq "aa747c502a898200f9e4fa21bac68136f886a0e27aec70ba06daf2e2a5cb5597"
    end
  end

  describe '#track' do 
    it "queues up an custom event" do
      expect(event_processor).to receive(:add_event).with(hash_including(kind: "custom", key: "custom_event_name", user: user, data: 42))
      client.track("custom_event_name", user, 42)
    end

    it "sanitizes the user in the event" do
      expect(event_processor).to receive(:add_event).with(hash_including(user: sanitized_numeric_key_user))
      client.track("custom_event_name", numeric_key_user, nil)
    end
  end

  describe '#identify' do 
    it "queues up an identify event" do
      expect(event_processor).to receive(:add_event).with(hash_including(kind: "identify", key: user[:key], user: user))
      client.identify(user)
    end

    it "sanitizes the user in the event" do
      expect(event_processor).to receive(:add_event).with(hash_including(user: sanitized_numeric_key_user))
      client.identify(numeric_key_user)
    end
  end

  describe '#log_exception' do
    it "log error data" do
      expect(client.instance_variable_get(:@config).logger).to receive(:error)
      begin
        raise StandardError.new 'asdf'
      rescue StandardError => exn
        client.send(:log_exception, 'caller', exn)
      end
    end
  end

  describe 'with send_events: false' do
    let(:config) { LaunchDarkly::Config.new({offline: true, send_events: false, update_processor: update_processor}) }
    let(:client) { subject.new("secret", config) }

    it "uses a NullEventProcessor" do
      ep = client.instance_variable_get(:@event_processor)
      expect(ep).to be_a(LaunchDarkly::NullEventProcessor)
    end
  end

  describe 'with send_events: true' do
    let(:config_with_events) { LaunchDarkly::Config.new({offline: false, send_events: true, update_processor: update_processor}) }
    let(:client_with_events) { subject.new("secret", config_with_events) }

    it "does not use a NullEventProcessor" do
      ep = client_with_events.instance_variable_get(:@event_processor)
      expect(ep).not_to be_a(LaunchDarkly::NullEventProcessor)
    end
  end

  class NullUpdateProcessor
    def start
    end

    def initialized?
      true
    end
  end
end