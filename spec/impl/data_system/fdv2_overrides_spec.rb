# frozen_string_literal: true

require "spec_helper"
require "model_builders"
require "override_test_components"
require "ldclient-rb/impl/data_system/fdv2"
require "ldclient-rb/data_system"

module LaunchDarkly
  module Impl
    module DataSystem
      describe FDv2, "with an override source" do
        let(:sdk_key) { "test-sdk-key" }
        let(:config) { LaunchDarkly::Config.new(logger: $null_log) }
        let(:override_flag) { { key: "flag", version: 1, on: false, offVariation: 0, variations: ["override"] } }
        let(:ld_flag) { { key: "flag", version: 1, on: false, offVariation: 0, variations: ["ld"] } }

        def config_with(overrides: nil, initializers: nil, synchronizers: nil)
          builder = LaunchDarkly::DataSystem.custom
          builder.initializers(initializers) if initializers
          builder.synchronizers(synchronizers) if synchronizers
          builder.overrides(overrides) if overrides
          builder.build
        end

        def with_fdv2(data_system_config, config: self.config)
          fdv2 = FDv2.new(sdk_key, config, data_system_config)
          begin
            yield fdv2
          ensure
            fdv2.stop
          end
        end

        it "reports that no override source is configured by default" do
          with_fdv2(config_with) do |fdv2|
            expect(fdv2.override_source_configured?).to be false
            expect(fdv2.store).not_to be_a(Overrides::Overlay)
          end
        end

        it "builds the override source at construction with the SDK key and configuration" do
          source = TestOverrideSource.new
          with_fdv2(config_with(overrides: source)) do |fdv2|
            expect(fdv2.override_source_configured?).to be true
            expect(source.build_args).to eq [sdk_key, config]
            expect(source.started?).to be false
          end
        end

        it "raises from construction when the override source cannot be built" do
          builder = Object.new
          builder.define_singleton_method(:build) { |_sdk_key, _config| raise ArgumentError, "no file paths" }

          expect { FDv2.new(sdk_key, config, config_with(overrides: builder)) }.to raise_error(ArgumentError, "no file paths")
        end

        it "serves reads through the overlay when an override source is configured" do
          source = TestOverrideSource.new([override_flag])
          with_fdv2(config_with(overrides: source)) do |fdv2|
            expect(fdv2.store).to be_a(Overrides::Overlay)
          end
        end

        it "starts the source with a sink before start returns, so the initial load is in effect at once" do
          source = TestOverrideSource.new([override_flag])
          with_fdv2(config_with(overrides: source, synchronizers: [HangingSynchronizer.new])) do |fdv2|
            fdv2.start

            expect(source.started?).to be true
            expect(source.sink).to be_a(Overrides::Sink)
            flag = fdv2.store.get(DataStore::FEATURES, "flag")
            expect(flag.variations).to eq ["override"]
            expect(flag.override?).to be true
          end
        end

        it "serves the override entry in preference to LaunchDarkly data" do
          source = TestOverrideSource.new([override_flag])
          initializer = TestDataInitializer.new(flags: { flag: ld_flag, other: ld_flag.merge(key: "other") })
          with_fdv2(config_with(overrides: source, initializers: [initializer])) do |fdv2|
            expect(fdv2.start.wait(2)).to be true

            expect(fdv2.store.get(DataStore::FEATURES, "flag").variations).to eq ["override"]
            expect(fdv2.store.get(DataStore::FEATURES, "other").variations).to eq ["ld"]
            expect(fdv2.store.all(DataStore::FEATURES).keys.sort).to eq [:flag, :other]
          end
        end

        it "applies a later snapshot from the source to the running system" do
          source = TestOverrideSource.new([override_flag])
          with_fdv2(config_with(overrides: source, synchronizers: [HangingSynchronizer.new])) do |fdv2|
            fdv2.start
            source.update([override_flag.merge(variations: ["changed"])])
            expect(fdv2.store.get(DataStore::FEATURES, "flag").variations).to eq ["changed"]

            source.update([])
            expect(fdv2.store.get(DataStore::FEATURES, "flag")).to be_nil
          end
        end

        it "does not let overrides affect data availability or initialization" do
          source = TestOverrideSource.new([override_flag])
          with_fdv2(config_with(overrides: source, synchronizers: [HangingSynchronizer.new])) do |fdv2|
            fdv2.start

            expect(fdv2.data_availability).to eq DataAvailability::DEFAULTS
            expect(fdv2.store.initialized?).to be false
            expect(fdv2.store.get(DataStore::FEATURES, "flag")).not_to be_nil
          end
        end

        it "notifies flag change listeners for an override change" do
          source = TestOverrideSource.new([])
          with_fdv2(config_with(overrides: source, synchronizers: [HangingSynchronizer.new])) do |fdv2|
            listener = CollectingFlagChangeListener.new
            fdv2.flag_change_broadcaster.add_listener(listener)
            fdv2.start

            source.update([override_flag])

            expect(listener.next_key).to eq "flag"
          end
        end

        it "stops the source when the data system stops" do
          source = TestOverrideSource.new([override_flag])
          fdv2 = FDv2.new(sdk_key, config, config_with(overrides: source, synchronizers: [HangingSynchronizer.new]))
          fdv2.start
          fdv2.stop

          expect(source.stopped?).to be true
        end

        it "stops the rest of the system when the source raises on stop" do
          source = TestOverrideSource.new([override_flag])
          source.define_singleton_method(:stop) { raise "boom" }
          synchronizer = HangingSynchronizer.new
          fdv2 = FDv2.new(sdk_key, config, config_with(overrides: source, synchronizers: [synchronizer]))
          fdv2.start

          expect { fdv2.stop }.not_to raise_error
          expect(Thread.list.map(&:name)).not_to include("FDv2-main")
        end

        it "does not build the override source when the SDK is offline" do
          source = TestOverrideSource.new([override_flag])
          offline = LaunchDarkly::Config.new(logger: $null_log, offline: true)
          with_fdv2(config_with(overrides: source), config: offline) do |fdv2|
            fdv2.start

            expect(source.build_args).to be_nil
            expect(fdv2.override_source_configured?).to be false
            expect(fdv2.store.get(DataStore::FEATURES, "flag")).to be_nil
          end
        end
      end
    end
  end
end
