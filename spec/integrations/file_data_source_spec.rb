require "spec_helper"
require "tempfile"

# see does not allow Ruby objects in YAML" for the purpose of the following two things
$created_bad_class = false
class BadClassWeShouldNotInstantiate < Hash
  def []=(key, value)
    $created_bad_class = true
  end
end

module LaunchDarkly
  module Integrations
    describe FileData do
      let(:full_flag_1_key) { "flag1" }
      let(:full_flag_1_value) { "on" }
      let(:flag_value_1_key) { "flag2" }
      let(:flag_value_1) { "value2" }
      let(:all_flag_keys) { [ full_flag_1_key.to_sym, flag_value_1_key.to_sym ] }
      let(:full_segment_1_key) { "seg1" }
      let(:all_segment_keys) { [ full_segment_1_key.to_sym ] }

      let(:invalid_json) { "My invalid JSON" }
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

      let(:alternate_flag_only_json) { <<-EOF
{
  "flags": {
    "flag1": {
      "key": "flag1",
      "on": false,
      "fallthrough": {
        "variation": 2
      },
      "variations": [ "fall", "off", "on" ]
    }
  }
}
EOF
      }

      let(:segment_only_json) { <<-EOF
{
  "segments": {
    "seg1": {
      "key": "seg1",
      "include": ["user1"]
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

      let(:unsafe_yaml) { <<-EOF
--- !ruby/hash:BadClassWeShouldNotInstantiate
foo: bar
EOF
      }

      let(:bad_file_path) { "no-such-file" }

      before do
        @config = LaunchDarkly::Config.new(logger: $null_log)
        @store = @config.feature_store

        @executor = SynchronousExecutor.new
        @status_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@executor, $null_log)
        @flag_change_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@executor, $null_log)
        @config.data_source_update_sink = LaunchDarkly::Impl::DataSource::UpdateSink.new(@store, @status_broadcaster, @flag_change_broadcaster)

        @tmp_dir = Dir.mktmpdir
      end

      after do
        FileUtils.rm_rf(@tmp_dir)
      end

      def make_temp_file(content)
        # Note that we don't create our files in the default temp file directory, but rather in an empty directory
        # that we made. That's because (depending on the platform) the temp file directory may contain huge numbers
        # of files, which can make the file watcher perform poorly enough to break the tests.
        file = Tempfile.new('flags', @tmp_dir)
        IO.write(file, content)
        file
      end

      def with_data_source(options, initialize_to_valid = false)
        factory = FileData.data_source(options)

        if initialize_to_valid
          # If the update sink receives an interrupted signal when the state is
          # still initializing, it will continue staying in the initializing phase.
          # Therefore, we set the state to valid before this test so we can
          # determine if the interrupted signal is actually generated.
          @config.data_source_update_sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
        end

        ds = factory.call('', @config)

        begin
          yield ds
        ensure
          ds.stop
        end
      end

      it "doesn't load flags prior to start" do
        file = make_temp_file('{"flagValues":{"key":"value"}}')
        with_data_source({ paths: [ file.path ] }) do |_|
          expect(@store.initialized?).to eq(false)
          expect(@store.all(LaunchDarkly::FEATURES)).to eq({})
          expect(@store.all(LaunchDarkly::SEGMENTS)).to eq({})
        end
      end

      it "loads flags on start - from JSON" do
        file = make_temp_file(all_properties_json)
        with_data_source({ paths: [ file.path ] }) do |ds|
          listener = ListenerSpy.new
          @status_broadcaster.add_listener(listener)

          ds.start
          expect(@store.initialized?).to eq(true)
          expect(@store.all(LaunchDarkly::FEATURES).keys).to eq(all_flag_keys)
          expect(@store.all(LaunchDarkly::SEGMENTS).keys).to eq(all_segment_keys)

          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
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

      it "does not allow Ruby objects in YAML" do
        # This tests for the vulnerability described here: https://trailofbits.github.io/rubysec/yaml/index.html
        # The file we're loading contains a hash with a custom Ruby class, BadClassWeShouldNotInstantiate (see top
        # of file). If we're not loading in safe mode, it will create an instance of that class and call its []=
        # method, which we've defined to set $created_bad_class to true. In safe mode, it refuses to parse this file.
        file = make_temp_file(unsafe_yaml)
        with_data_source({ paths: [file.path ] }) do |ds|
          event = ds.start
          expect(event.set?).to eq(true)
          expect(ds.initialized?).to eq(false)
          expect($created_bad_class).to eq(false)
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

      it "can load multiple files" do
        file1 = make_temp_file(flag_only_json)
        file2 = make_temp_file(segment_only_json)
        with_data_source({ paths: [ file1.path, file2.path ] }) do |ds|
          ds.start
          expect(@store.initialized?).to eq(true)
          expect(@store.all(LaunchDarkly::FEATURES).keys).to eq([ full_flag_1_key.to_sym ])
          expect(@store.all(LaunchDarkly::SEGMENTS).keys).to eq([ full_segment_1_key.to_sym ])
        end
      end

      it "file loading failure results in interrupted status" do
        file1 = make_temp_file(flag_only_json)
        file2 = make_temp_file(invalid_json)
        with_data_source({ paths: [ file1.path, file2.path ] }, true) do |ds|
          listener = ListenerSpy.new
          @status_broadcaster.add_listener(listener)

          ds.start
          expect(@store.initialized?).to eq(false)
          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
        end
      end

      it "does not allow duplicate keys" do
        file1 = make_temp_file(flag_only_json)
        file2 = make_temp_file(flag_only_json)
        with_data_source({ paths: [ file1.path, file2.path ] }) do |ds|
          ds.start
          expect(@store.initialized?).to eq(false)
          expect(@store.all(LaunchDarkly::FEATURES).keys).to eq([])
        end
      end

      it "allows duplicate keys and uses the last loaded version when allow-duplicates is true" do
        file1 = make_temp_file(flag_only_json)
        file2 = make_temp_file(alternate_flag_only_json)
        with_data_source({ paths: [ file1.path, file2.path ], allow_duplicates: true }) do |ds|
          ds.start
          expect(@store.initialized?).to eq(true)
          expect(@store.all(LaunchDarkly::FEATURES).keys).to_not eq([])
          expect(@store.all(LaunchDarkly::FEATURES)[:flag1][:on]).to eq(false)
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

      def test_auto_reload(options)
        file = make_temp_file(flag_only_json)
        options[:paths] = [ file.path ]

        with_data_source(options) do |ds|
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

      it "reloads modified file if auto-update is on" do
        test_auto_reload({ auto_update: true })
      end

      it "reloads modified file in polling mode" do
        test_auto_reload({ auto_update: true, force_polling: true, poll_interval: 0.1 })
      end

      it "evaluates simplified flag with client as expected" do
        file = make_temp_file(all_properties_json)
        factory = FileData.data_source({ paths: file.path })
        config = LaunchDarkly::Config.new(send_events: false, data_source: factory)
        client = LaunchDarkly::LDClient.new('sdkKey', config)

        begin
          value = client.variation(flag_value_1_key, { key: 'user', kind: 'user' }, '')
          expect(value).to eq(flag_value_1)
        ensure
          client.close
        end
      end

      it "evaluates full flag with client as expected" do
        file = make_temp_file(all_properties_json)
        factory = FileData.data_source({ paths: file.path })
        config = LaunchDarkly::Config.new(send_events: false, data_source: factory)
        client = LaunchDarkly::LDClient.new('sdkKey', config)

        begin
          value = client.variation(full_flag_1_key, { key: 'user', kind: 'user' }, '')
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
  end
end
