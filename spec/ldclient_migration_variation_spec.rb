require "ldclient-rb"
require "mock_components"
require "model_builders"

module LaunchDarkly
  describe "LDClient migration variation tests" do
    it "returns off if default stage is invalid" do
      td = Integrations::TestData.data_source

      with_client(test_config(data_source: td)) do |client|
        result, tracker, err = client.migration_variation("flagkey", basic_context, "invalid stage should default to off")

        expect(result).to eq(LaunchDarkly::Migrations::STAGE_OFF)
        expect(tracker).not_to be_nil
        expect(err).to eq("feature flag not found")
      end
    end

    it "returns error if flag isn't found" do
      td = Integrations::TestData.data_source

      with_client(test_config(data_source: td)) do |client|
        result, tracker, err = client.migration_variation("flagkey", basic_context, LaunchDarkly::Migrations::STAGE_LIVE)

        expect(result).to eq(LaunchDarkly::Migrations::STAGE_LIVE)
        expect(tracker).not_to be_nil
        expect(err).to eq("feature flag not found")
      end
    end

    it "flag doesn't return a valid stage" do
      td = Integrations::TestData.data_source
      td.update(td.flag("flagkey").variations("value").variation_for_all(0))

      with_client(test_config(data_source: td)) do |client|
        result, tracker, err = client.migration_variation("flagkey", basic_context, LaunchDarkly::Migrations::STAGE_LIVE)

        expect(result).to eq(LaunchDarkly::Migrations::STAGE_LIVE)
        expect(tracker).not_to be_nil
        expect(err).to eq("value is not a valid stage; using default stage")
      end
    end

    it "can determine correct stage from flag" do
      LaunchDarkly::Migrations::VALID_STAGES.each do |stage|
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations(stage).variation_for_all(0))

        with_client(test_config(data_source: td)) do |client|
          result, tracker, err = client.migration_variation("flagkey", basic_context, LaunchDarkly::Migrations::STAGE_LIVE)

          expect(result).to eq(stage)
          expect(tracker).not_to be_nil
          expect(err).to be_nil
        end
      end
    end
  end
end
