require "spec_helper"
require "json"

describe LaunchDarkly::FeatureFlagsState do
  subject { LaunchDarkly::FeatureFlagsState }

  it "can get flag value" do
    state = subject.new(true)
    flag_state = { key: 'key', value: 'value', variation: 1, reason: LaunchDarkly::EvaluationReason.fallthrough(false) }
    state.add_flag(flag_state, false, false)

    expect(state.flag_value('key')).to eq 'value'
  end

  it "returns nil for unknown flag" do
    state = subject.new(true)

    expect(state.flag_value('key')).to be nil
  end

  it "can be converted to values map" do
    state = subject.new(true)
    flag_state1 = { key: 'key1', value: 'value1', variation: 0, reason: LaunchDarkly::EvaluationReason.fallthrough(false) }
    flag_state2 = { key: 'key2', value: 'value2', variation: 1, reason: LaunchDarkly::EvaluationReason.fallthrough(false) }
    state.add_flag(flag_state1, false, false)
    state.add_flag(flag_state2, false, false)

    expect(state.values_map).to eq({ 'key1' => 'value1', 'key2' => 'value2' })
  end

  it "can be converted to JSON structure" do
    state = subject.new(true)
    flag_state1 = { key: "key1", version: 100, trackEvents: false, value: 'value1', variation: 0, reason: LaunchDarkly::EvaluationReason.fallthrough(false) }
    # rubocop:disable Layout/LineLength
    flag_state2 = { key: "key2", version: 200, trackEvents: true, debugEventsUntilDate: 1000, value: 'value2', variation: 1, reason: LaunchDarkly::EvaluationReason.fallthrough(false) }
    state.add_flag(flag_state1, false, false)
    state.add_flag(flag_state2, false, false)

    result = state.as_json
    expect(result).to eq({
      'key1' => 'value1',
      'key2' => 'value2',
      '$flagsState' => {
        'key1' => {
          :variation => 0,
          :version => 100,
        },
        'key2' => {
          :variation => 1,
          :version => 200,
          :trackEvents => true,
          :debugEventsUntilDate => 1000,
        },
      },
      '$valid' => true,
    })
  end

  it "can be converted to JSON string" do
    state = subject.new(true)
    flag_state1 = { key: "key1", version: 100, trackEvents: false, value: 'value1', variation: 0, reason: LaunchDarkly::EvaluationReason.fallthrough(false) }
    # rubocop:disable Layout/LineLength
    flag_state2 = { key: "key2", version: 200, trackEvents: true, debugEventsUntilDate: 1000, value: 'value2', variation: 1, reason: LaunchDarkly::EvaluationReason.fallthrough(false) }
    state.add_flag(flag_state1, false, false)
    state.add_flag(flag_state2, false, false)

    object = state.as_json
    str = state.to_json
    expect(object.to_json).to eq(str)
  end

  it "uses our custom serializer with JSON.generate" do
    state = subject.new(true)
    flag_state1 = { key: "key1", version: 100, trackEvents: false, value: 'value1', variation: 0, reason: LaunchDarkly::EvaluationReason.fallthrough(false) }
    # rubocop:disable Layout/LineLength
    flag_state2 = { key: "key2", version: 200, trackEvents: true, debugEventsUntilDate: 1000, value: 'value2', variation: 1, reason: LaunchDarkly::EvaluationReason.fallthrough(false) }
    state.add_flag(flag_state1, false, false)
    state.add_flag(flag_state2, false, false)

    stringFromToJson = state.to_json
    stringFromGenerate = JSON.generate(state)
    expect(stringFromGenerate).to eq(stringFromToJson)
  end
end
