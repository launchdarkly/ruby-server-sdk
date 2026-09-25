require "spec_helper"
require "override_test_components"
require "ldclient-rb/impl/file_data"

require "json"

#
# Runs the OVERRIDE specification's test vectors in spec/fixtures/override-vectors/vectors.json.
# Each vector sets up LaunchDarkly data, an override layer, and an initialization state. The test
# evaluates one flag through the full client stack and checks the value, the variation index, and
# the reason against the vector's expectations, using the comparison rules from the vectors' README.
#
module LaunchDarkly
  describe LDClient, "OVERRIDE specification vectors" do
    VECTORS_PATH = File.expand_path("fixtures/override-vectors/vectors.json", __dir__)

    # The vectors' semantics are versioned. A schema change means this runner needs review.
    SUPPORTED_VECTOR_SCHEMA = "0.4.0"

    vector_file = JSON.parse(File.read(VECTORS_PATH), symbolize_names: true)

    it "uses vectors with the supported schema version" do
      expect(vector_file[:schemaVersion]).to eq SUPPORTED_VECTOR_SCHEMA
      expect(vector_file[:vectors]).not_to be_empty
    end

    def override_definitions(overrides)
      flags = (overrides[:flags] || {}).values
      (overrides[:flagValues] || {}).each do |key, value|
        flags << Impl::FileData.make_flag_with_value(key.to_s, value, 1, off: true)
      end
      [flags, (overrides[:segments] || {}).values]
    end

    def build_client(vector)
      flags, segments = override_definitions(vector[:overrides] || {})
      source = TestOverrideSource.new(flags, segments)
      ld_data = vector[:launchDarklyData]

      builder = DataSystem.custom.overrides(source)
      if ld_data[:initialized]
        builder.initializers([TestDataInitializer.new(flags: ld_data[:flags] || {}, segments: ld_data[:segments] || {})])
        wait = 5
      else
        # With no data sources at all, the client would consider cached data available rather than
        # applying its not-initialized handling. A synchronizer that never delivers anything avoids that.
        builder.synchronizers([HangingSynchronizer.new])
        wait = 0
      end

      config = Config.new(data_system_config: builder.build, send_events: false, logger: $null_log)
      client = LDClient.new("sdk-key", config, wait)
      # The summary marker is the marking the client hands to the event processor for this
      # evaluation. Event handling keys on that scalar, not on the reason.
      events = RecordingEventProcessor.new
      client.instance_variable_set(:@event_processor, events)
      [client, events]
    end

    # Compares the actual reason against only the fields present in the expected reason. An expected
    # reason that omits overrideAffected requires the actual reason to report false, which is never
    # serialized, or to omit it.
    def expect_reason(expected, actual)
      actual_json = JSON.parse(actual.to_json)
      expected.each do |field, value|
        expect(actual_json[field.to_s]).to eq(value), "reason field #{field}"
      end
      unless expected.key?(:overrideAffected)
        expect(actual_json["overrideAffected"]).to be_nil
        expect(actual.override_affected).to be false
      end
    end

    vector_file[:vectors].each do |vector|
      it "#{vector[:group]}: #{vector[:description]}" do
        client, events = build_client(vector)
        begin
          expect(client.initialized?).to eq(vector[:launchDarklyData][:initialized])

          evaluate = vector[:evaluate]
          context = LDContext.create(evaluate[:context])
          detail = client.variation_detail(evaluate[:flagKey], context, evaluate[:defaultValue])
          expected = vector[:expect]

          expect(detail.value).to eq(expected[:value])
          if expected[:variationIndex].nil?
            expect(detail.variation_index).to be_nil
          else
            expect(detail.variation_index).to eq(expected[:variationIndex])
          end
          expect_reason(expected[:reason], detail.reason)

          unless expected[:summaryOverrideAffected].nil?
            records = events.records_for(evaluate[:flagKey])
            expect(records.length).to eq(1), "expected exactly one evaluation record for the flag"
            expect(records[0].override_affected).to eq(expected[:summaryOverrideAffected]), "summaryOverrideAffected"
          end
        ensure
          client.close
        end
      end
    end
  end
end
