require "spec_helper"

describe LaunchDarkly::FeatureFlagsState do
  subject { LaunchDarkly::FeatureFlagsState }

  it "can get flag value" do
    state = subject.new(true)
    flag = { key: 'key' }
    state.add_flag(flag, 'value', 1)

    expect(state.flag_value('key')).to eq 'value'
  end

  it "returns nil for unknown flag" do
    state = subject.new(true)

    expect(state.flag_value('key')).to be nil
  end

  it "can be converted to values map" do
    state = subject.new(true)
    flag1 = { key: 'key1' }
    flag2 = { key: 'key2' }
    state.add_flag(flag1, 'value1', 0)
    state.add_flag(flag2, 'value2', 1)

    expect(state.values_map).to eq({ 'key1' => 'value1', 'key2' => 'value2' })
  end

  it "can be converted to JSON structure" do
    state = subject.new(true)
    flag1 = { key: "key1", version: 100, offVariation: 0, variations: [ 'value1' ], trackEvents: false }
    flag2 = { key: "key2", version: 200, offVariation: 1, variations: [ 'x', 'value2' ], trackEvents: true, debugEventsUntilDate: 1000 }
    state.add_flag(flag1, 'value1', 0)
    state.add_flag(flag2, 'value2', 1)
    
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
      }
    })
  end

  it "can be converted to JSON string" do
    state = subject.new(true)
    flag1 = { key: "key1", version: 100, offVariation: 0, variations: [ 'value1' ], trackEvents: false }
    flag2 = { key: "key2", version: 200, offVariation: 1, variations: [ 'x', 'value2' ], trackEvents: true, debugEventsUntilDate: 1000 }
    state.add_flag(flag1, 'value1', 0)
    state.add_flag(flag2, 'value2', 1)
    
    object = state.as_json
    str = state.to_json
    expect(object.to_json).to eq(str)
  end
end
