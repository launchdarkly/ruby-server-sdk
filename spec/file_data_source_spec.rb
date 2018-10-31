require "spec_helper"
require "tempfile"

describe LaunchDarkly::FileDataSource do
  let(:full_flag_1_key) { "flag1" }
  let(:full_flag_1_value) { "on" }
  let(:flag_value_1_key) { "flag2" }
  let(:flag_value_1) { "value2" }
  let(:all_flag_keys) { [ full_flag_1_key.to_sym, flag_value_1_key.to_sym ] }
  let(:full_segment_1_key) { "seg1" }
  let(:all_segment_keys) { [ full_segment_1_key.to_sym ] }

  let(:flag_only_json) { <<-EOF
  {
    "flags": {
      "flag1": {
        "key": "flag1",
        "on": true,
        "fallthrough": {
          "variation": 2
        },
        "variations": [ "fall", "off", "on" ]
      }
    }
  }
EOF
}

  let(:all_properties_json) { <<-EOF
  {
    "flags": {
      "flag1": {
        "key": "flag1",
        "on": true,
        "fallthrough": {
          "variation": 2
        },
        "variations": [ "fall", "off", "on" ]
      }
    },
    "flagValues": {
      "flag2": "value2"
    },
    "segments": {
      "seg1": {
        "key": "seg1",
        "include": ["user1"]
      }
    }
  }
EOF
  }

  let(:all_properties_yaml) { <<-EOF
---
flags:
  flag1:
    key: flag1
    "on": true
flagValues:
  flag2: value2
segments:
  seg1:
    key: seg1
    include: ["user1"]  
EOF
  }

  let(:bad_file_path) { "no-such-file" }

  before do
    @config = LaunchDarkly::Config.new
    @store = @config.feature_store
  end

  def make_temp_file(content)
    file = Tempfile.new('flags')
    IO.write(file, content)
    file
  end

  def with_data_source(options)
    factory = LaunchDarkly::FileDataSource.factory(options)
    ds = factory.call('', @config)
    begin
      yield ds
    ensure
      ds.stop
    end
  end

  it "doesn't load flags prior to start" do
    file = make_temp_file('{"flagValues":{"key":"value"}}')
    with_data_source({ paths: [ file.path ] }) do |ds|
      expect(@store.initialized?).to eq(false)
      expect(@store.all(LaunchDarkly::FEATURES)).to eq({})
      expect(@store.all(LaunchDarkly::SEGMENTS)).to eq({})
    end
  end

  it "loads flags on start - from JSON" do
    file = make_temp_file(all_properties_json)
    with_data_source({ paths: [ file.path ] }) do |ds|
      ds.start
      expect(@store.initialized?).to eq(true)
      expect(@store.all(LaunchDarkly::FEATURES).keys).to eq(all_flag_keys)
      expect(@store.all(LaunchDarkly::SEGMENTS).keys).to eq(all_segment_keys)
    end
  end

  it "loads flags on start - from YAML" do
    file = make_temp_file(all_properties_yaml)
    with_data_source({ paths: [ file.path ] }) do |ds|
      ds.start
      expect(@store.initialized?).to eq(true)
      expect(@store.all(LaunchDarkly::FEATURES).keys).to eq(all_flag_keys)
      expect(@store.all(LaunchDarkly::SEGMENTS).keys).to eq(all_segment_keys)
    end
  end

  it "sets start event and initialized on successful load" do
    file = make_temp_file(all_properties_json)
    with_data_source({ paths: [ file.path ] }) do |ds|
      event = ds.start
      expect(event.set?).to eq(true)
      expect(ds.initialized?).to eq(true)
    end
  end

  it "sets start event and does not set initialized on unsuccessful load" do
    with_data_source({ paths: [ bad_file_path ] }) do |ds|
      event = ds.start
      expect(event.set?).to eq(true)
      expect(ds.initialized?).to eq(false)
    end
  end

  it "does not reload modified file if auto-update is off" do
    file = make_temp_file(flag_only_json)

    with_data_source({ paths: [ file.path ] }) do |ds|
      event = ds.start
      expect(event.set?).to eq(true)
      expect(@store.all(LaunchDarkly::SEGMENTS).keys).to eq([])

      IO.write(file, all_properties_json)
      sleep(0.5)
      expect(@store.all(LaunchDarkly::SEGMENTS).keys).to eq([])
    end
  end

  it "reloads modified file if auto-update is on" do
    file = make_temp_file(flag_only_json)

    with_data_source({ auto_update: true, paths: [ file.path ] }) do |ds|
      event = ds.start
      expect(event.set?).to eq(true)
      expect(@store.all(LaunchDarkly::SEGMENTS).keys).to eq([])
      
      sleep(1)
      IO.write(file, all_properties_json)
      
      max_time = 10
      ok = wait_for_condition(10) { @store.all(LaunchDarkly::SEGMENTS).keys == all_segment_keys }
      expect(ok).to eq(true), "Waited #{max_time}s after modifying file and it did not reload"
    end
  end

  it "evaluates simplified flag with client as expected" do
    file = make_temp_file(all_properties_json)
    factory = LaunchDarkly::FileDataSource.factory({ paths: file.path })
    config = LaunchDarkly::Config.new(send_events: false, update_processor_factory: factory)
    client = LaunchDarkly::LDClient.new('sdkKey', config)

    begin
      value = client.variation(flag_value_1_key, { key: 'user' }, '')
      expect(value).to eq(flag_value_1)
    ensure
      client.close
    end
  end

  it "evaluates full flag with client as expected" do
    file = make_temp_file(all_properties_json)
    factory = LaunchDarkly::FileDataSource.factory({ paths: file.path })
    config = LaunchDarkly::Config.new(send_events: false, update_processor_factory: factory)
    client = LaunchDarkly::LDClient.new('sdkKey', config)

    begin
      value = client.variation(full_flag_1_key, { key: 'user' }, '')
      expect(value).to eq(full_flag_1_value)
    ensure
      client.close
    end
  end
  
  def wait_for_condition(max_time)
    deadline = Time.now + max_time
    while Time.now < deadline
      return true if yield
      sleep(0.1)
    end
    false
  end
end
