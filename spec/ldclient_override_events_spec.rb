require "spec_helper"
require "events_test_util"
require "model_builders"
require "override_test_components"

module LaunchDarkly
  describe LDClient, "events for override-affected evaluations" do
    let(:context) { LDContext.create({ key: "user-key", kind: "user" }) }
    let(:debug_until) { (Time.now.to_f * 1000).to_i + 1000000 }

    def flag(key, value, version: 100, prereqs: [], segment: nil, track: true)
      data = {
        key: key, version: version, on: true, offVariation: 0, fallthrough: { variation: 1 },
        variations: ["#{value}-off", value],
        prerequisites: prereqs.map { |p| { key: p, variation: 1 } },
        trackEvents: track
      }
      data[:debugEventsUntilDate] = debug_until if track
      if segment
        data[:rules] = [{ id: "segment-rule", variation: 1, clauses: [{ attribute: "", op: "segmentMatch", values: [segment] }] }]
        data[:fallthrough] = { variation: 0 }
      end
      data
    end

    def segment(key, *included)
      { key: key, version: 100, included: included }
    end

    def data_system(overrides:, flags: {}, segments: {})
      DataSystem.custom
        .initializers([TestDataInitializer.new(flags: flags, segments: segments)])
        .overrides(overrides)
        .build
    end

    def with_recording_client(data_system_config)
      config = Config.new(data_system_config: data_system_config, send_events: false, logger: $null_log)
      client = LDClient.new("sdk-key", config, 5)
      events = RecordingEventProcessor.new
      client.instance_variable_set(:@event_processor, events)
      begin
        yield client, events
      ensure
        client.close
      end
    end

    describe "records handed to the event processor" do
      it "carries the marking of a directly overridden flag" do
        source = TestOverrideSource.new([flag("flag", "override")])
        with_recording_client(data_system(overrides: source, flags: { flag: flag("flag", "ld") })) do |client, events|
          client.variation("flag", context, "default")

          record = events.records_for("flag")[0]
          expect(record.override_affected).to be true
          expect(record.track_events).to be true
          expect(record.debug_until).to eq debug_until
          expect(record.value).to eq "override"
        end
      end

      it "does not mark an unaffected flag" do
        source = TestOverrideSource.new([flag("flag", "override")])
        with_recording_client(data_system(overrides: source, flags: { normal: flag("normal", "n") })) do |client, events|
          client.variation("normal", context, "default")

          expect(events.records_for("normal")[0].override_affected).to be false
        end
      end

      it "marks a flag affected through an overridden segment" do
        source = TestOverrideSource.new([], [segment("seg", context.key)])
        with_recording_client(data_system(overrides: source, flags: { flag: flag("flag", "included", segment: "seg") },
          segments: { seg: segment("seg") })) do |client, events|
          expect(client.variation("flag", context, "default")).to eq "included"

          expect(events.records_for("flag")[0].override_affected).to be true
        end
      end

      it "marks the prerequisite record by the prerequisite's own reads" do
        source = TestOverrideSource.new([flag("overridden-prereq", "op")])
        flags = {
          "overridden-prereq": flag("overridden-prereq", "ld-op", version: 50),
          "plain-prereq": flag("plain-prereq", "pp"),
          top: flag("top", "t", prereqs: ["overridden-prereq", "plain-prereq"]),
        }
        with_recording_client(data_system(overrides: source, flags: flags)) do |client, events|
          expect(client.variation("top", context, "default")).to eq "t"

          top = events.records_for("top")[0]
          expect(top.override_affected).to be true
          overridden = events.records_for("overridden-prereq")[0]
          expect(overridden.override_affected).to be true
          expect(overridden.version).to eq 100
          expect(overridden.prereq_of).to eq "top"
          plain = events.records_for("plain-prereq")[0]
          expect(plain.override_affected).to be false
          expect(plain.prereq_of).to eq "top"
        end
      end

      it "does not mark an unknown flag" do
        source = TestOverrideSource.new([flag("flag", "override")])
        with_recording_client(data_system(overrides: source)) do |client, events|
          client.variation("unknown", context, "default")

          expect(events.records_for("unknown")[0].override_affected).to be false
        end
      end

      it "marks an error record by the flag's own marker when the evaluation raises" do
        source = TestOverrideSource.new([flag("flag", "override")])
        with_recording_client(data_system(overrides: source)) do |client, events|
          evaluator = client.instance_variable_get(:@evaluator)
          allow(evaluator).to receive(:evaluate).and_raise(RuntimeError, "boom")

          expect(client.variation("flag", context, "default")).to eq "default"

          record = events.records_for("flag")[0]
          expect(record.override_affected).to be true
          expect(record.variation).to be_nil
        end
      end
    end

    describe "all_flags_state" do
      it "turns off event tracking for override-affected flags and keeps it for others" do
        source = TestOverrideSource.new([flag("direct", "override")], [segment("seg", context.key)])
        flags = {
          direct: flag("direct", "ld"),
          transitive: flag("transitive", "included", segment: "seg"),
          normal: flag("normal", "n"),
        }
        with_recording_client(data_system(overrides: source, flags: flags, segments: { seg: segment("seg") })) do |client, _|
          state = client.all_flags_state(context, with_reasons: true)
          meta = state.as_json["$flagsState"]

          expect(state.values_map).to eq({ "direct" => "override", "transitive" => "included", "normal" => "n" })
          %w[direct transitive].each do |key|
            expect(meta[key]).not_to have_key(:trackEvents)
            expect(meta[key]).not_to have_key(:trackReason)
            expect(meta[key]).not_to have_key(:debugEventsUntilDate)
            expect(meta[key][:version]).to eq 100
            expect(meta[key][:reason].override_affected).to be true
          end
          expect(meta["normal"][:trackEvents]).to be true
          expect(meta["normal"][:debugEventsUntilDate]).to eq debug_until
          expect(meta["normal"][:reason].override_affected).to be false
        end
      end

      it "turns off tracking that an experiment would otherwise require" do
        experiment = flag("experiment", "e", track: false).merge(trackEventsFallthrough: true)
        source = TestOverrideSource.new([experiment])
        with_recording_client(data_system(overrides: source, flags: { experiment: experiment })) do |client, _|
          meta = client.all_flags_state(context).as_json["$flagsState"]

          expect(meta["experiment"]).not_to have_key(:trackEvents)
          expect(meta["experiment"]).not_to have_key(:trackReason)
        end
      end

      it "omits details for an override-affected flag when details are only wanted for tracked flags" do
        source = TestOverrideSource.new([flag("direct", "override")])
        with_recording_client(data_system(overrides: source, flags: { normal: flag("normal", "n") })) do |client, _|
          meta = client.all_flags_state(context, details_only_for_tracked_flags: true).as_json["$flagsState"]

          expect(meta["direct"]).not_to have_key(:version)
          expect(meta["normal"][:version]).to eq 100
        end
      end
    end

    describe "delivered payload" do
      def with_sending_client(data_system_config)
        config = Config.new(data_system_config: data_system_config, logger: $null_log, diagnostic_opt_out: true)
        client = LDClient.new("sdk-key", config, 5)
        sender = FakeEventSender.new
        ep = EventProcessor.new("sdk-key", config, nil, nil, { event_sender: sender })
        client.instance_variable_set(:@event_processor, ep)
        begin
          yield client, ep, sender
        ensure
          ep.stop
          client.close
        end
      end

      def payload(ep, sender)
        ep.flush
        ep.wait_until_inactive
        sender.analytics_payloads.pop(timeout: 5)
      end

      it "sends only an index event and a marked summary counter for an overridden flag that tracks events" do
        source = TestOverrideSource.new([flag("flag", "override", version: 300)])
        with_sending_client(data_system(overrides: source, flags: { normal: flag("normal", "n", track: false) })) do |client, ep, sender|
          2.times { client.variation("flag", context, "default1") }
          client.variation("normal", context, "default2")

          events = payload(ep, sender)
          expect(events.map { |e| e[:kind] }.sort).to eq %w[index summary]
          summary = events.detect { |e| e[:kind] == "summary" }
          expect(summary[:features][:flag][:default]).to eq "default1"
          expected_counters = [{ version: 300, variation: 1, value: "override", count: 2, overrideAffected: true }]
          expect(summary[:features][:flag][:counters]).to eq(expected_counters)
          expect(summary[:features][:normal][:counters]).to eq([{ version: 100, variation: 1, value: "n", count: 1 }])
        end
      end

      it "sends the individual event for an unaffected prerequisite inside a marked evaluation and none for the marked ones" do
        source = TestOverrideSource.new([flag("overridden-prereq", "op", version: 200)])
        flags = {
          "overridden-prereq": flag("overridden-prereq", "ld-op"),
          "plain-prereq": flag("plain-prereq", "pp"),
          mixed: flag("mixed", "m", prereqs: ["overridden-prereq", "plain-prereq"]),
        }
        with_sending_client(data_system(overrides: source, flags: flags)) do |client, ep, sender|
          expect(client.variation("mixed", context, "default")).to eq "m"

          events = payload(ep, sender)
          feature_events = events.select { |e| e[:kind] == "feature" }
          expect(feature_events.map { |e| e[:key] }).to eq ["plain-prereq"]
          expect(feature_events[0][:prereqOf]).to eq "mixed"
          # The unaffected prerequisite is in debug mode too, so it alone produces a debug event.
          expect(events.select { |e| e[:kind] == "debug" }.map { |e| e[:key] }).to eq ["plain-prereq"]

          summary = events.detect { |e| e[:kind] == "summary" }
          expect(summary[:features][:mixed][:counters]).to eq([{ version: 100, variation: 1, value: "m", count: 1, overrideAffected: true }])
          expect(summary[:features][:"overridden-prereq"][:counters]).to eq([{ version: 200, variation: 1, value: "op", count: 1, overrideAffected: true }])
          expect(summary[:features][:"plain-prereq"][:counters]).to eq([{ version: 100, variation: 1, value: "pp", count: 1 }])
        end
      end

      it "sends the usual feature and debug events when nothing is overridden" do
        source = TestOverrideSource.new([])
        with_sending_client(data_system(overrides: source, flags: { flag: flag("flag", "ld") })) do |client, ep, sender|
          client.variation("flag", context, "default")

          events = payload(ep, sender)
          expect(events.map { |e| e[:kind] }.sort).to eq %w[debug feature index summary]
          summary = events.detect { |e| e[:kind] == "summary" }
          expect(summary[:features][:flag][:counters]).to eq([{ version: 100, variation: 1, value: "ld", count: 1 }])
        end
      end
    end
  end
end
