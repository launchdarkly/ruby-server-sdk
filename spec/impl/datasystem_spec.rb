require "spec_helper"
require "ldclient-rb/impl/datasystem"

module LaunchDarkly
  module Impl
    describe DataSystem do
      # Test that methods raise NotImplementedError when not overridden
      describe "contract enforcement" do
        let(:test_instance) do
          Class.new do
            include DataSystem
          end.new
        end

        it "start raises NotImplementedError" do
          ready_event = double("Event")
          expect { test_instance.start(ready_event) }.to raise_error(NotImplementedError, /must implement #start/)
        end

        it "stop raises NotImplementedError" do
          expect { test_instance.stop }.to raise_error(NotImplementedError, /must implement #stop/)
        end

        it "data_source_status_provider raises NotImplementedError" do
          expect { test_instance.data_source_status_provider }.to raise_error(NotImplementedError, /must implement #data_source_status_provider/)
        end

        it "data_store_status_provider raises NotImplementedError" do
          expect { test_instance.data_store_status_provider }.to raise_error(NotImplementedError, /must implement #data_store_status_provider/)
        end

        it "flag_tracker raises NotImplementedError" do
          expect { test_instance.flag_tracker }.to raise_error(NotImplementedError, /must implement #flag_tracker/)
        end

        it "data_availability raises NotImplementedError" do
          expect { test_instance.data_availability }.to raise_error(NotImplementedError, /must implement #data_availability/)
        end

        it "target_availability raises NotImplementedError" do
          expect { test_instance.target_availability }.to raise_error(NotImplementedError, /must implement #target_availability/)
        end

        it "store raises NotImplementedError" do
          expect { test_instance.store }.to raise_error(NotImplementedError, /must implement #store/)
        end

        it "set_flag_value_eval_fn raises NotImplementedError" do
          expect { test_instance.set_flag_value_eval_fn(nil) }.to raise_error(NotImplementedError, /must implement #set_flag_value_eval_fn/)
        end
      end

      # Test DataAvailability constants and methods
      describe "DataAvailability" do
        it "defines DEFAULTS constant" do
          expect(DataSystem::DataAvailability::DEFAULTS).to eq(:defaults)
        end

        it "defines CACHED constant" do
          expect(DataSystem::DataAvailability::CACHED).to eq(:cached)
        end

        it "defines REFRESHED constant" do
          expect(DataSystem::DataAvailability::REFRESHED).to eq(:refreshed)
        end

        it "defines ALL constant with all availability levels" do
          expect(DataSystem::DataAvailability::ALL).to eq([:defaults, :cached, :refreshed])
        end

        describe ".at_least?" do
          it "returns true when levels are equal" do
            expect(DataSystem::DataAvailability.at_least?(:cached, :cached)).to be true
          end

          it "returns true when self is REFRESHED" do
            expect(DataSystem::DataAvailability.at_least?(:refreshed, :defaults)).to be true
            expect(DataSystem::DataAvailability.at_least?(:refreshed, :cached)).to be true
          end

          it "returns true when self is CACHED and other is DEFAULTS" do
            expect(DataSystem::DataAvailability.at_least?(:cached, :defaults)).to be true
          end

          it "returns false when self is DEFAULTS and other is CACHED" do
            expect(DataSystem::DataAvailability.at_least?(:defaults, :cached)).to be false
          end

          it "returns false when self is DEFAULTS and other is REFRESHED" do
            expect(DataSystem::DataAvailability.at_least?(:defaults, :refreshed)).to be false
          end

          it "returns false when self is CACHED and other is REFRESHED" do
            expect(DataSystem::DataAvailability.at_least?(:cached, :refreshed)).to be false
          end
        end
      end

      # Test Update class
      describe "Update" do
        it "initializes with required state parameter" do
          update = DataSystem::Update.new(state: :valid)
          expect(update.state).to eq(:valid)
          expect(update.change_set).to be_nil
          expect(update.error).to be_nil
          expect(update.revert_to_fdv1).to be false
          expect(update.environment_id).to be_nil
        end

        it "initializes with all optional parameters" do
          change_set = double("ChangeSet")
          error = double("ErrorInfo")

          update = DataSystem::Update.new(
            state: :interrupted,
            change_set: change_set,
            error: error,
            revert_to_fdv1: true,
            environment_id: "env-123"
          )

          expect(update.state).to eq(:interrupted)
          expect(update.change_set).to eq(change_set)
          expect(update.error).to eq(error)
          expect(update.revert_to_fdv1).to be true
          expect(update.environment_id).to eq("env-123")
        end
      end

      # Test DiagnosticAccumulator mixin
      describe "DiagnosticAccumulator" do
        let(:test_instance) do
          Class.new do
            include DataSystem::DiagnosticAccumulator
          end.new
        end

        it "record_stream_init raises NotImplementedError" do
          expect { test_instance.record_stream_init(0, 0, false) }.to raise_error(NotImplementedError, /must implement #record_stream_init/)
        end

        it "record_events_in_batch raises NotImplementedError" do
          expect { test_instance.record_events_in_batch(0) }.to raise_error(NotImplementedError, /must implement #record_events_in_batch/)
        end

        it "create_event_and_reset raises NotImplementedError" do
          expect { test_instance.create_event_and_reset(0, 0) }.to raise_error(NotImplementedError, /must implement #create_event_and_reset/)
        end
      end

      # Test DiagnosticSource mixin
      describe "DiagnosticSource" do
        let(:test_instance) do
          Class.new do
            include DataSystem::DiagnosticSource
          end.new
        end

        it "set_diagnostic_accumulator raises NotImplementedError" do
          expect { test_instance.set_diagnostic_accumulator(nil) }.to raise_error(NotImplementedError, /must implement #set_diagnostic_accumulator/)
        end
      end

      # Test Initializer mixin
      describe "Initializer" do
        let(:test_instance) do
          Class.new do
            include DataSystem::Initializer
          end.new
        end

        it "fetch raises NotImplementedError" do
          expect { test_instance.fetch }.to raise_error(NotImplementedError, /must implement #fetch/)
        end
      end

      # Test Synchronizer mixin
      describe "Synchronizer" do
        let(:test_instance) do
          Class.new do
            include DataSystem::Synchronizer
          end.new
        end

        it "sync raises NotImplementedError" do
          expect { test_instance.sync }.to raise_error(NotImplementedError, /must implement #sync/)
        end
      end
    end
  end
end
