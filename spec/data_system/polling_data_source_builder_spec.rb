# frozen_string_literal: true

require "spec_helper"
require "capturing_logger"
require "ldclient-rb/impl/data_system/polling"

module LaunchDarkly
  module DataSystem
    [PollingDataSourceBuilder, FDv1PollingDataSourceBuilder].each do |builder_class|
      RSpec.describe builder_class do
        let(:logger) { CapturingLogger.new }
        let(:config) { Config.new(logger: logger) }

        def poll_interval_of(builder)
          data_source = builder.build("sdk-key", config)
          data_source.instance_variable_get(:@poll_interval)
        end

        it "defaults the poll interval to 30 seconds" do
          expect(poll_interval_of(described_class.new)).to eq 30
          expect(logger.output).not_to include("Poll interval")
        end

        it "keeps a poll interval larger than the minimum" do
          expect(poll_interval_of(described_class.new.poll_interval(45))).to eq 45
          expect(logger.output).not_to include("Poll interval")
        end

        it "keeps a poll interval equal to the minimum" do
          expect(poll_interval_of(described_class.new.poll_interval(30))).to eq 30
          expect(logger.output).not_to include("Poll interval")
        end

        it "replaces a poll interval below the minimum with 30 seconds and logs a warning" do
          expect(poll_interval_of(described_class.new.poll_interval(5))).to eq 30
          expect(logger.output).to match(/WARN.*Poll interval 5 is less than the minimum; using 30 seconds/)
        end
      end
    end
  end
end
