require "ldclient-rb/impl/diagnostic_events"

require "spec_helper"

module LaunchDarkly
  module Impl
    describe DiagnosticAccumulator do
      subject { DiagnosticAccumulator }

      let(:sdk_key) { "sdk_key" }
      let(:default_id) { subject.create_diagnostic_id("my-key") }
      let(:default_acc) { subject.new(default_id) }

      it "creates unique ID with SDK key suffix" do
        id1 = subject.create_diagnostic_id("1234567890")
        expect(id1[:sdkKeySuffix]).to eq "567890"
        expect(id1[:diagnosticId]).not_to be_nil

        id2 = subject.create_diagnostic_id("1234567890")
        expect(id2[:diagnosticId]).not_to eq id1[:diagnosticId]
      end

      describe "init event" do
        def expected_default_config
          {
            allAttributesPrivate: false,
            connectTimeoutMillis: Config.default_connect_timeout * 1000,
            customBaseURI: false,
            customEventsURI: false,
            customStreamURI: false,
            diagnosticRecordingIntervalMillis: Config.default_diagnostic_recording_interval * 1000,
            eventsCapacity: Config.default_capacity,
            eventsFlushIntervalMillis: Config.default_flush_interval * 1000,
            pollingIntervalMillis: Config.default_poll_interval * 1000,
            socketTimeoutMillis: Config.default_read_timeout * 1000,
            streamingDisabled: false,
            userKeysCapacity: Config.default_context_keys_capacity,
            userKeysFlushIntervalMillis: Config.default_context_keys_flush_interval * 1000,
            usingProxy: false,
            usingRelayDaemon: false,
          }
        end

        it "has basic fields" do
          event = default_acc.create_init_event(Config.new)
          expect(event[:kind]).to eq 'diagnostic-init'
          expect(event[:creationDate]).not_to be_nil
          expect(event[:id]).to eq default_id
        end

        it "can have default config data" do
          event = default_acc.create_init_event(Config.new)
          expect(event[:configuration]).to eq expected_default_config
        end

        it "can have custom config data" do
          changes_and_expected = [
            [ { all_attributes_private: true }, { allAttributesPrivate: true } ],
            [ { connect_timeout: 46 }, { connectTimeoutMillis: 46000 } ],
            [ { base_uri: 'http://custom' }, { customBaseURI: true } ],
            [ { events_uri: 'http://custom' }, { customEventsURI: true } ],
            [ { stream_uri: 'http://custom' }, { customStreamURI: true } ],
            [ { diagnostic_recording_interval: 9999 }, { diagnosticRecordingIntervalMillis: 9999000 } ],
            [ { capacity: 4000 }, { eventsCapacity: 4000 } ],
            [ { flush_interval: 46 }, { eventsFlushIntervalMillis: 46000 } ],
            [ { poll_interval: 999 }, { pollingIntervalMillis: 999000 } ],
            [ { read_timeout: 46 }, { socketTimeoutMillis: 46000 } ],
            [ { stream: false }, { streamingDisabled: true } ],
            [ { context_keys_capacity: 999 }, { userKeysCapacity: 999 } ],
            [ { context_keys_flush_interval: 999 }, { userKeysFlushIntervalMillis: 999000 } ],
            [ { use_ldd: true }, { usingRelayDaemon: true } ],
          ]
          changes_and_expected.each do |config_values, expected_values|
            config = Config.new(config_values)
            event = default_acc.create_init_event(config)
            expect(event[:configuration]).to eq expected_default_config.merge(expected_values)
          end
        end

        ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY'].each do |name|
          it "detects proxy #{name}" do
            begin
              ENV[name] = 'http://my-proxy'
              event = default_acc.create_init_event(Config.new)
              expect(event[:configuration][:usingProxy]).to be true
            ensure
              ENV[name] = nil
            end
          end
        end

        it "has expected SDK data" do
          event = default_acc.create_init_event(Config.new)
          expect(event[:sdk]).to eq ({
            name: 'ruby-server-sdk',
            version: LaunchDarkly::VERSION,
          })
        end

        it "has expected SDK data with wrapper" do
          event = default_acc.create_init_event(Config.new(wrapper_name: 'my-wrapper', wrapper_version: '2.0'))
          expect(event[:sdk]).to eq ({
            name: 'ruby-server-sdk',
            version: LaunchDarkly::VERSION,
            wrapperName: 'my-wrapper',
            wrapperVersion: '2.0',
          })
        end

        it "has expected platform data" do
          event = default_acc.create_init_event(Config.new)
          expect(event[:platform]).to include ({
            name: 'ruby',
          })
        end
      end

      describe "periodic event" do
        it "has correct default values" do
          acc = subject.new(default_id)
          event = acc.create_periodic_event_and_reset(2, 3, 4)
          expect(event).to include({
            kind: 'diagnostic',
            id: default_id,
            droppedEvents: 2,
            deduplicatedUsers: 3,
            eventsInLastBatch: 4,
            streamInits: [],
          })
          expect(event[:creationDate]).not_to be_nil
          expect(event[:dataSinceDate]).not_to be_nil
        end

        it "can add stream init" do
          acc = subject.new(default_id)
          acc.record_stream_init(1000, false, 2000)
          event = acc.create_periodic_event_and_reset(0, 0, 0)
          expect(event[:streamInits]).to eq [{ timestamp: 1000, failed: false, durationMillis: 2000 }]
        end

        it "resets fields after creating event" do
          acc = subject.new(default_id)
          acc.record_stream_init(1000, false, 2000)
          event1 = acc.create_periodic_event_and_reset(2, 3, 4)
          event2 = acc.create_periodic_event_and_reset(5, 6, 7)
          expect(event1).to include ({
            droppedEvents: 2,
            deduplicatedUsers: 3,
            eventsInLastBatch: 4,
            streamInits: [{ timestamp: 1000, failed: false, durationMillis: 2000 }],
          })
          expect(event2).to include ({
            dataSinceDate: event1[:creationDate],
            droppedEvents: 5,
            deduplicatedUsers: 6,
            eventsInLastBatch: 7,
            streamInits: [],
          })
        end
      end
    end
  end
end
