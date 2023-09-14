require 'ldclient-rb/interfaces'
require "ldclient-rb"

module LaunchDarkly
  module Impl
    module Migrations
      describe OpTracker do
        let(:flag_data) { LaunchDarkly::Integrations::TestData::FlagBuilder.new("feature").build(1) }
        let(:flag) { LaunchDarkly::Impl::Model::FeatureFlag.new(flag_data) }
        let(:context) { LaunchDarkly::LDContext.with_key("user-key") }
        let(:detail) { LaunchDarkly::EvaluationDetail.new(true, 0, LaunchDarkly::EvaluationReason.fallthrough) }

        def minimal_tracker()
          tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
          tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
          tracker.invoked(LaunchDarkly::Migrations::ORIGIN_OLD)
          tracker.invoked(LaunchDarkly::Migrations::ORIGIN_NEW)

          tracker
        end

        it "can build successfully" do
          event = minimal_tracker.build
          expect(event).to be_instance_of(LaunchDarkly::Impl::MigrationOpEvent)
        end

        describe "can track invocations" do
          it "individually" do
            [LaunchDarkly::Migrations::ORIGIN_OLD, LaunchDarkly::Migrations::ORIGIN_NEW].each do |origin|
              tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
              tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
              tracker.invoked(origin)

              event = tracker.build
              expect(event.invoked.length).to eq(1)
              expect(event.invoked.include?(origin)).to be true
            end
          end

          it "together" do
            event = minimal_tracker.build
            expect(event.invoked.length).to be(2)
          end

          it "will ignore invalid origins" do
            tracker = minimal_tracker
            tracker.invoked(:invalid_origin)
            tracker.invoked(:another_invalid_origin)

            event = tracker.build
            expect(event.invoked.length).to be(2)
            expect(event.invoked.include?(LaunchDarkly::Migrations::ORIGIN_OLD)).to be true
            expect(event.invoked.include?(LaunchDarkly::Migrations::ORIGIN_NEW)).to be true
          end
        end

        describe "can track consistency" do
          it "with no sampling ratio" do
            [true, false].each do |expected_consistent|
              tracker = minimal_tracker
              tracker.consistent(-> { expected_consistent })
              event = tracker.build

              expect(event.consistency_check).to be expected_consistent
              expect(event.consistency_check_ratio).to be_nil
            end
          end

          it "with explicit sampling ratio of 1" do
            settings = LaunchDarkly::Integrations::TestData::FlagBuilder::FlagMigrationSettingsBuilder.new
            settings.check_ratio(1)

            builder = LaunchDarkly::Integrations::TestData::FlagBuilder.new("feature")
            builder.migration_settings(settings.build)
            flag = LaunchDarkly::Impl::Model::FeatureFlag.new(builder.build(1))
            context = LaunchDarkly::LDContext.with_key("user-key")
            detail = LaunchDarkly::EvaluationDetail.new(true, 0, LaunchDarkly::EvaluationReason.fallthrough)

            tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
            tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
            tracker.invoked(LaunchDarkly::Migrations::ORIGIN_OLD)
            tracker.invoked(LaunchDarkly::Migrations::ORIGIN_NEW)

            [true, false].each do |expected_consistent|
              tracker.consistent(-> { expected_consistent })
              event = tracker.build

              expect(event.consistency_check).to be expected_consistent
              expect(event.consistency_check_ratio).to be_nil
            end
          end

          it "unless disabled with sampling ratio of 0" do
            settings = LaunchDarkly::Integrations::TestData::FlagBuilder::FlagMigrationSettingsBuilder.new
            settings.check_ratio(0)

            builder = LaunchDarkly::Integrations::TestData::FlagBuilder.new("feature")
            builder.migration_settings(settings.build)
            flag = LaunchDarkly::Impl::Model::FeatureFlag.new(builder.build(1))
            context = LaunchDarkly::LDContext.with_key("user-key")
            detail = LaunchDarkly::EvaluationDetail.new(true, 0, LaunchDarkly::EvaluationReason.fallthrough)

            tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
            tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
            tracker.invoked(LaunchDarkly::Migrations::ORIGIN_OLD)

            [true, false].each do |expected_consistent|
              tracker.consistent(-> { expected_consistent })
              event = tracker.build

              expect(event.consistency_check).to be_nil
              expect(event.consistency_check_ratio).to be_nil
            end
          end

          it "when supplied a non-trivial sampling ratio" do
            settings = LaunchDarkly::Integrations::TestData::FlagBuilder::FlagMigrationSettingsBuilder.new
            settings.check_ratio(10)

            builder = LaunchDarkly::Integrations::TestData::FlagBuilder.new("feature")
            builder.migration_settings(settings.build)
            flag = LaunchDarkly::Impl::Model::FeatureFlag.new(builder.build(1))
            context = LaunchDarkly::LDContext.with_key("user-key")
            detail = LaunchDarkly::EvaluationDetail.new(true, 0, LaunchDarkly::EvaluationReason.fallthrough)

            sampler = LaunchDarkly::Impl::Sampler.new(Random.new(0))


            count = 0
            1_000.times do |_|
              tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
              tracker.instance_variable_set(:@sampler, sampler)
              tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
              tracker.invoked(LaunchDarkly::Migrations::ORIGIN_OLD)
              tracker.invoked(LaunchDarkly::Migrations::ORIGIN_NEW)

              tracker.consistent(-> { true })
              event = tracker.build

              unless event.consistency_check.nil?
                count += 1
                expect(event.consistency_check_ratio).to eq(10)
              end
            end

            expect(count).to eq(98)
          end
        end

        describe "can track errors" do
          it "individually" do
            [LaunchDarkly::Migrations::ORIGIN_OLD, LaunchDarkly::Migrations::ORIGIN_NEW].each do |origin|
              tracker = minimal_tracker
              tracker.error(origin)

              event = tracker.build
              expect(event.errors.length).to eq(1)
              expect(event.errors.include?(origin)).to be true
            end
          end

          it "together" do
            tracker = minimal_tracker
            tracker.error(LaunchDarkly::Migrations::ORIGIN_OLD)
            tracker.error(LaunchDarkly::Migrations::ORIGIN_NEW)

            event = tracker.build
            expect(event.errors.length).to be(2)
          end

          it "will ignore invalid origins" do
            tracker = minimal_tracker
            tracker.error(:invalid_origin)
            tracker.error(:another_invalid_origin)

            event = tracker.build
            expect(event.errors.length).to be(0)
          end
        end

        describe "can track latencies" do
          it "individually" do
            [LaunchDarkly::Migrations::ORIGIN_OLD, LaunchDarkly::Migrations::ORIGIN_NEW].each do |origin|
              tracker = minimal_tracker
              tracker.latency(origin, 5.4)

              event = tracker.build
              expect(event.latencies.length).to eq(1)
              expect(event.latencies[origin]).to eq(5.4)
            end
          end

          it "together" do
            tracker = minimal_tracker
            tracker.latency(LaunchDarkly::Migrations::ORIGIN_OLD, 2)
            tracker.latency(LaunchDarkly::Migrations::ORIGIN_NEW, 3)

            event = tracker.build
            expect(event.latencies.length).to be(2)
            expect(event.latencies[LaunchDarkly::Migrations::ORIGIN_OLD]).to eq(2)
            expect(event.latencies[LaunchDarkly::Migrations::ORIGIN_NEW]).to eq(3)
          end

          it "will ignore invalid origins" do
            tracker = minimal_tracker
            tracker.latency(:invalid_origin, 3)
            tracker.latency(:another_invalid_origin, 10)

            event = tracker.build
            expect(event.latencies.length).to be(0)
          end

          it "will ignore invalid durations" do
            tracker = minimal_tracker
            tracker.latency(LaunchDarkly::Migrations::ORIGIN_OLD, -1)
            tracker.latency(LaunchDarkly::Migrations::ORIGIN_NEW, nil)

            event = tracker.build
            expect(event.latencies.length).to be(0)
          end
        end

        describe "can handle build failures" do
          it "without providing a flag" do
            tracker = OpTracker.new(nil, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
            tracker.operation(LaunchDarkly::Migrations::OP_WRITE)

            event = tracker.build
            expect(event).to eq("flag not provided")
          end

          it "without calling invoked" do
            tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
            tracker.operation(LaunchDarkly::Migrations::OP_WRITE)

            event = tracker.build
            expect(event).to eq("no origins were invoked")
          end

          it "without operation" do
            tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
            event = tracker.build
            expect(event).to eq("operation not provided")
          end

          it "with invalid context " do
            invalid = LaunchDarkly::LDContext.create({kind: 'multi', key: 'invalid'})
            tracker = OpTracker.new(flag, invalid, detail, LaunchDarkly::Migrations::STAGE_LIVE)
            tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
            tracker.invoked(LaunchDarkly::Migrations::ORIGIN_OLD)

            event = tracker.build
            expect(event).to eq("provided context was invalid")
          end

          describe "detects when invoked doesn't align with" do
            it "latency" do
              tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
              tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
              tracker.invoked(LaunchDarkly::Migrations::ORIGIN_NEW)
              tracker.latency(LaunchDarkly::Migrations::ORIGIN_OLD, 10)

              event = tracker.build
              expect(event).to eq("provided latency for origin 'old' without recording invocation")

              tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
              tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
              tracker.invoked(LaunchDarkly::Migrations::ORIGIN_OLD)
              tracker.latency(LaunchDarkly::Migrations::ORIGIN_NEW, 10)

              event = tracker.build
              expect(event).to eq("provided latency for origin 'new' without recording invocation")

            end

            it "errors" do
              tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
              tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
              tracker.invoked(LaunchDarkly::Migrations::ORIGIN_NEW)
              tracker.error(LaunchDarkly::Migrations::ORIGIN_OLD)

              event = tracker.build
              expect(event).to eq("provided error for origin 'old' without recording invocation")

              tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
              tracker.operation(LaunchDarkly::Migrations::OP_WRITE)
              tracker.invoked(LaunchDarkly::Migrations::ORIGIN_OLD)
              tracker.error(LaunchDarkly::Migrations::ORIGIN_NEW)

              event = tracker.build
              expect(event).to eq("provided error for origin 'new' without recording invocation")
            end

            it "consistent" do
              tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
              tracker.operation(LaunchDarkly::Migrations::OP_READ)
              tracker.invoked(LaunchDarkly::Migrations::ORIGIN_OLD)
              tracker.consistent(->{ true })

              event = tracker.build
              expect(event).to eq("provided consistency without recording both invocations")

              tracker = OpTracker.new(flag, context, detail, LaunchDarkly::Migrations::STAGE_LIVE)
              tracker.operation(LaunchDarkly::Migrations::OP_READ)
              tracker.invoked(LaunchDarkly::Migrations::ORIGIN_NEW)
              tracker.consistent(->{ true })

              event = tracker.build
              expect(event).to eq("provided consistency without recording both invocations")
            end
          end
        end
      end
    end
  end
end
