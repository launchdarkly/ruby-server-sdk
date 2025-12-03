require "spec_helper"
require "mock_components"
require "ldclient-rb/impl/data_system/fdv1"

module LaunchDarkly
  module Impl
    module DataSystem
      describe FDv1 do
        let(:sdk_key) { "test-sdk-key" }
        let(:config) { LaunchDarkly::Config.new }
        subject { FDv1.new(sdk_key, config) }

        describe "#initialize" do
          it "injects data_source_update_sink into config" do
            subject  # Force creation of FDv1 instance
            expect(config.data_source_update_sink).to be_a(LaunchDarkly::Impl::DataSource::UpdateSink)
          end
        end

        describe "#start" do
          it "returns a Concurrent::Event" do
            ready_event = subject.start
            expect(ready_event).to be_a(Concurrent::Event)
          end

          it "creates streaming processor by default" do
            allow(LaunchDarkly::StreamProcessor).to receive(:new).and_call_original
            subject.start
            expect(LaunchDarkly::StreamProcessor).to have_received(:new).with(sdk_key, config, nil)
          end

          context "with polling mode" do
            let(:config) { LaunchDarkly::Config.new(stream: false) }

            it "creates polling processor" do
              allow(LaunchDarkly::PollingProcessor).to receive(:new).and_call_original
              subject.start
              expect(LaunchDarkly::PollingProcessor).to have_received(:new)
            end
          end

          context "with offline mode" do
            let(:config) { LaunchDarkly::Config.new(offline: true) }

            it "creates null processor" do
              expect(LaunchDarkly::Impl::DataSource::NullUpdateProcessor).to receive(:new).and_call_original
              ready_event = subject.start
              expect(ready_event.set?).to be true
            end
          end

          context "with LDD mode" do
            let(:config) { LaunchDarkly::Config.new(use_ldd: true) }

            it "creates null processor" do
              expect(LaunchDarkly::Impl::DataSource::NullUpdateProcessor).to receive(:new).and_call_original
              ready_event = subject.start
              expect(ready_event.set?).to be true
            end
          end

          context "with custom data source factory" do
            let(:custom_processor) { MockUpdateProcessor.new }
            let(:factory) { ->(sdk_key, config, diag) { custom_processor } }
            let(:config) { LaunchDarkly::Config.new(data_source: factory) }

            it "calls factory with sdk_key, config, and diagnostic_accumulator" do
              expect(factory).to receive(:call).with(sdk_key, config, nil).and_return(custom_processor)
              subject.start
            end

            it "passes diagnostic_accumulator if set" do
              diagnostic_accumulator = double("DiagnosticAccumulator")
              subject.set_diagnostic_accumulator(diagnostic_accumulator)
              expect(factory).to receive(:call).with(sdk_key, config, diagnostic_accumulator).and_return(custom_processor)
              subject.start
            end

            context "with arity 2 factory" do
              let(:factory) { ->(sdk_key, config) { custom_processor } }

              it "calls factory without diagnostic_accumulator" do
                expect(factory).to receive(:call).with(sdk_key, config).and_return(custom_processor)
                subject.start
              end
            end
          end

          context "with custom data source instance" do
            let(:custom_processor) { MockUpdateProcessor.new }
            let(:config) { LaunchDarkly::Config.new(data_source: custom_processor) }

            it "uses the instance directly" do
              ready_event = subject.start
              expect(ready_event).to be_a(Concurrent::Event)
            end
          end

          it "returns the same event on multiple calls" do
            first_event = subject.start
            second_event = subject.start
            third_event = subject.start

            expect(second_event).to be(first_event)
            expect(third_event).to be(first_event)
          end

          it "does not create a new processor on subsequent calls" do
            processor = MockUpdateProcessor.new
            allow(subject).to receive(:make_update_processor).and_return(processor)

            subject.start
            expect(subject).to have_received(:make_update_processor).once

            subject.start
            subject.start
            # Should still only be called once
            expect(subject).to have_received(:make_update_processor).once
          end
        end

        describe "#stop" do
          it "stops the update processor" do
            processor = MockUpdateProcessor.new
            allow(subject).to receive(:make_update_processor).and_return(processor)
            subject.start
            expect(processor).to receive(:stop)
            subject.stop
          end

          it "shuts down the executor" do
            executor = subject.instance_variable_get(:@shared_executor)
            expect(executor).to receive(:shutdown)
            subject.stop
          end

          it "does nothing if not started" do
            expect { subject.stop }.not_to raise_error
          end
        end

        describe "#store" do
          it "returns the store wrapper" do
            expect(subject.store).to be_a(LaunchDarkly::Impl::FeatureStoreClientWrapper)
          end
        end

        describe "#set_diagnostic_accumulator" do
          it "stores the diagnostic accumulator" do
            diagnostic_accumulator = double("DiagnosticAccumulator")
            expect { subject.set_diagnostic_accumulator(diagnostic_accumulator) }.not_to raise_error
          end
        end

        describe "#data_source_status_provider" do
          it "returns the data source status provider" do
            expect(subject.data_source_status_provider).to be_a(LaunchDarkly::Impl::DataSource::StatusProvider)
          end
        end

        describe "#data_store_status_provider" do
          it "returns the data store status provider" do
            expect(subject.data_store_status_provider).to be_a(LaunchDarkly::Impl::DataStore::StatusProvider)
          end
        end

        describe "#flag_change_broadcaster" do
          it "returns the flag change broadcaster" do
            expect(subject.flag_change_broadcaster).to be_a(LaunchDarkly::Impl::Broadcaster)
          end
        end

        describe "#data_availability" do
          context "when offline" do
            let(:config) { LaunchDarkly::Config.new(offline: true) }

            it "returns DEFAULTS" do
              expect(subject.data_availability).to eq(DataAvailability::DEFAULTS)
            end
          end

          context "when update processor is initialized" do
            it "returns REFRESHED" do
              processor = MockUpdateProcessor.new
              allow(subject).to receive(:make_update_processor).and_return(processor)
              subject.start
              processor.ready.set

              expect(subject.data_availability).to eq(DataAvailability::REFRESHED)
            end
          end

          context "when store is initialized but processor is not" do
            it "returns CACHED" do
              # Initialize the store
              subject.store.init({})

              expect(subject.data_availability).to eq(DataAvailability::CACHED)
            end
          end

          context "when neither processor nor store are initialized" do
            it "returns DEFAULTS" do
              expect(subject.data_availability).to eq(DataAvailability::DEFAULTS)
            end
          end

          context "in LDD mode" do
            let(:config) { LaunchDarkly::Config.new(use_ldd: true) }

            it "always returns CACHED for backwards compatibility" do
              subject.start
              # Returns CACHED even when store is empty
              expect(subject.data_availability).to eq(DataAvailability::CACHED)

              # Still returns CACHED when store is initialized
              subject.store.init({})
              expect(subject.data_availability).to eq(DataAvailability::CACHED)
            end
          end
        end

        describe "#target_availability" do
          context "when offline" do
            let(:config) { LaunchDarkly::Config.new(offline: true) }

            it "returns DEFAULTS" do
              expect(subject.target_availability).to eq(DataAvailability::DEFAULTS)
            end
          end

          context "when not offline" do
            it "returns REFRESHED" do
              expect(subject.target_availability).to eq(DataAvailability::REFRESHED)
            end
          end

          context "with LDD mode" do
            let(:config) { LaunchDarkly::Config.new(use_ldd: true) }

            it "returns CACHED" do
              expect(subject.target_availability).to eq(DataAvailability::CACHED)
            end
          end
        end

        describe "integration with diagnostic accumulator" do
          it "passes diagnostic accumulator to streaming processor" do
            diagnostic_accumulator = double("DiagnosticAccumulator")
            subject.set_diagnostic_accumulator(diagnostic_accumulator)

            expect(LaunchDarkly::StreamProcessor).to receive(:new).with(sdk_key, config, diagnostic_accumulator).and_call_original
            subject.start
          end

          context "with polling mode" do
            let(:config) { LaunchDarkly::Config.new(stream: false) }

            it "does not pass diagnostic accumulator to polling processor" do
              diagnostic_accumulator = double("DiagnosticAccumulator")
              subject.set_diagnostic_accumulator(diagnostic_accumulator)

              # PollingProcessor doesn't accept diagnostic_accumulator
              expect(LaunchDarkly::PollingProcessor).to receive(:new).with(config, anything).and_call_original
              subject.start
            end
          end
        end
      end
    end
  end
end

