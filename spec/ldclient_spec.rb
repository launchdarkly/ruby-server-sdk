require "spec_helper"


describe LaunchDarkly::LDClient do
  subject { LaunchDarkly::LDClient }
  let(:offline_config) { LaunchDarkly::Config.new({offline: true}) }
  let(:offline_client) do
    subject.new("secret", offline_config)
  end
  let(:update_processor) { LaunchDarkly::NullUpdateProcessor.new }
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
    feature_with_value = { key: "key", on: false, offVariation: 0, variations: ["value"], version: 100,
      trackEvents: true, debugEventsUntilDate: 1000 }

    it "returns the default value if the client is offline" do
      result = offline_client.variation("doesntmatter", user, "default")
      expect(result).to eq "default"
    end

    it "returns the default value for an unknown feature" do
      expect(client.variation("badkey", user, "default")).to eq "default"
    end

    it "queues a feature request event for an unknown feature" do
      expect(event_processor).to receive(:add_event).with(hash_including(
        kind: "feature", key: "badkey", user: user, value: "default", default: "default"
      ))
      client.variation("badkey", user, "default")
    end

    it "returns the value for an existing feature" do
      config.feature_store.init({ LaunchDarkly::FEATURES => {} })
      config.feature_store.upsert(LaunchDarkly::FEATURES, feature_with_value)
      expect(client.variation("key", user, "default")).to eq "value"
    end

    it "queues a feature request event for an existing feature" do
      config.feature_store.init({ LaunchDarkly::FEATURES => {} })
      config.feature_store.upsert(LaunchDarkly::FEATURES, feature_with_value)
      expect(event_processor).to receive(:add_event).with(hash_including(
        kind: "feature",
        key: "key",
        version: 100,
        user: user,
        variation: 0,
        value: "value",
        default: "default",
        trackEvents: true,
        debugEventsUntilDate: 1000
      ))
      client.variation("key", user, "default")
    end

    it "queues a feature event for an existing feature when user is nil" do
      config.feature_store.init({ LaunchDarkly::FEATURES => {} })
      config.feature_store.upsert(LaunchDarkly::FEATURES, feature_with_value)
      expect(event_processor).to receive(:add_event).with(hash_including(
        kind: "feature",
        key: "key",
        version: 100,
        user: nil,
        variation: nil,
        value: "default",
        default: "default",
        trackEvents: true,
        debugEventsUntilDate: 1000
      ))
      client.variation("key", nil, "default")
    end

    it "queues a feature event for an existing feature when user key is nil" do
      config.feature_store.init({ LaunchDarkly::FEATURES => {} })
      config.feature_store.upsert(LaunchDarkly::FEATURES, feature_with_value)
      bad_user = { name: "Bob" }
      expect(event_processor).to receive(:add_event).with(hash_including(
        kind: "feature",
        key: "key",
        version: 100,
        user: bad_user,
        variation: nil,
        value: "default",
        default: "default",
        trackEvents: true,
        debugEventsUntilDate: 1000
      ))
      client.variation("key", bad_user, "default")
    end
  end

  describe '#variation_detail' do
    feature_with_value = { key: "key", on: false, offVariation: 0, variations: ["value"], version: 100,
      trackEvents: true, debugEventsUntilDate: 1000 }

    it "returns the default value if the client is offline" do
      result = offline_client.variation_detail("doesntmatter", user, "default")
      expected = LaunchDarkly::EvaluationDetail.new("default", nil, { kind: 'ERROR', errorKind: 'CLIENT_NOT_READY' })
      expect(result).to eq expected
    end

    it "returns the default value for an unknown feature" do
      result = client.variation_detail("badkey", user, "default")
      expected = LaunchDarkly::EvaluationDetail.new("default", nil, { kind: 'ERROR', errorKind: 'FLAG_NOT_FOUND'})
      expect(result).to eq expected
    end

    it "queues a feature request event for an unknown feature" do
      expect(event_processor).to receive(:add_event).with(hash_including(
        kind: "feature", key: "badkey", user: user, value: "default", default: "default",
        reason: { kind: 'ERROR', errorKind: 'FLAG_NOT_FOUND' }
      ))
      client.variation_detail("badkey", user, "default")
    end

    it "returns a value for an existing feature" do
      config.feature_store.init({ LaunchDarkly::FEATURES => {} })
      config.feature_store.upsert(LaunchDarkly::FEATURES, feature_with_value)
      result = client.variation_detail("key", user, "default")
      expected = LaunchDarkly::EvaluationDetail.new("value", 0, { kind: 'OFF' })
      expect(result).to eq expected
    end

    it "queues a feature request event for an existing feature" do
      config.feature_store.init({ LaunchDarkly::FEATURES => {} })
      config.feature_store.upsert(LaunchDarkly::FEATURES, feature_with_value)
      expect(event_processor).to receive(:add_event).with(hash_including(
        kind: "feature",
        key: "key",
        version: 100,
        user: user,
        variation: 0,
        value: "value",
        default: "default",
        trackEvents: true,
        debugEventsUntilDate: 1000,
        reason: { kind: "OFF" }
      ))
      client.variation_detail("key", user, "default")
    end
  end

  describe '#all_flags' do
    let(:flag1) { { key: "key1", offVariation: 0, variations: [ 'value1' ] } }
    let(:flag2) { { key: "key2", offVariation: 0, variations: [ 'value2' ] } }

    it "returns flag values" do
      config.feature_store.init({ LaunchDarkly::FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

      result = client.all_flags({ key: 'userkey' })
      expect(result).to eq({ 'key1' => 'value1', 'key2' => 'value2' })
    end

    it "returns empty map for nil user" do
      config.feature_store.init({ LaunchDarkly::FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

      result = client.all_flags(nil)
      expect(result).to eq({})
    end

    it "returns empty map for nil user key" do
      config.feature_store.init({ LaunchDarkly::FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

      result = client.all_flags({})
      expect(result).to eq({})
    end

    it "returns empty map if offline" do
      offline_config.feature_store.init({ LaunchDarkly::FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

      result = offline_client.all_flags(nil)
      expect(result).to eq({})
    end
  end

  describe '#all_flags_state' do
    let(:flag1) { { key: "key1", version: 100, offVariation: 0, variations: [ 'value1' ], trackEvents: false } }
    let(:flag2) { { key: "key2", version: 200, offVariation: 1, variations: [ 'x', 'value2' ], trackEvents: true, debugEventsUntilDate: 1000 } }

    it "returns flags state" do
      config.feature_store.init({ LaunchDarkly::FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

      state = client.all_flags_state({ key: 'userkey' })
      expect(state.valid?).to be true

      values = state.values_map
      expect(values).to eq({ 'key1' => 'value1', 'key2' => 'value2' })
      
      result = state.as_json
      expect(result).to eq({
        'key1' => 'value1',
        'key2' => 'value2',
        '$flagsState' => {
          'key1' => {
            :variation => 0,
            :version => 100,
            :trackEvents => false
          },
          'key2' => {
            :variation => 1,
            :version => 200,
            :trackEvents => true,
            :debugEventsUntilDate => 1000
          }
        },
        '$valid' => true
      })
    end

    it "can be filtered for only client-side flags" do
      flag1 = { key: "server-side-1", offVariation: 0, variations: [ 'a' ], clientSide: false }
      flag2 = { key: "server-side-2", offVariation: 0, variations: [ 'b' ], clientSide: false }
      flag3 = { key: "client-side-1", offVariation: 0, variations: [ 'value1' ], clientSide: true }
      flag4 = { key: "client-side-2", offVariation: 0, variations: [ 'value2' ], clientSide: true }
      config.feature_store.init({ LaunchDarkly::FEATURES => {
        flag1[:key] => flag1, flag2[:key] => flag2, flag3[:key] => flag3, flag4[:key] => flag4
      }})

      state = client.all_flags_state({ key: 'userkey' }, client_side_only: true)
      expect(state.valid?).to be true

      values = state.values_map
      expect(values).to eq({ 'client-side-1' => 'value1', 'client-side-2' => 'value2' })
    end

    it "returns empty state for nil user" do
      config.feature_store.init({ LaunchDarkly::FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

      state = client.all_flags_state(nil)
      expect(state.valid?).to be false
      expect(state.values_map).to eq({})
    end

    it "returns empty state for nil user key" do
      config.feature_store.init({ LaunchDarkly::FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

      state = client.all_flags_state({})
      expect(state.valid?).to be false
      expect(state.values_map).to eq({})
    end

    it "returns empty state if offline" do
      offline_config.feature_store.init({ LaunchDarkly::FEATURES => { 'key1' => flag1, 'key2' => flag2 } })

      state = offline_client.all_flags_state({ key: 'userkey' })
      expect(state.valid?).to be false
      expect(state.values_map).to eq({})
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
end