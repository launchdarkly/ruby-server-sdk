require 'ldclient-rb/interfaces'
require 'ldclient-rb/impl/migrations/tracker'

module LaunchDarkly
  module Impl
    module Migrations
      describe OpTracker do
        subject { OpTracker }

        let(:flag_data) { LaunchDarkly::Integrations::TestData::FlagBuilder.new("feature").build(1) }
        let(:flag) { LaunchDarkly::Impl::Model::FeatureFlag.new(flag_data) }
        let(:context) { context = LaunchDarkly::LDContext.with_key("user-key") }
        let(:detail) { LaunchDarkly::EvaluationDetail.new(true, 0, LaunchDarkly::EvaluationReason.fallthrough) }

        def minimal_tracker()
          tracker = subject.new(flag, context, detail, LaunchDarkly::Interfaces::Migrations::STAGE_LIVE)
          tracker.operation(LaunchDarkly::Interfaces::Migrations::OP_WRITE)
          tracker.invoked(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD)
          tracker.invoked(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW)

          tracker
        end

        it "can build successfully" do
          event = minimal_tracker.build
          expect(event).to be_instance_of(LaunchDarkly::Impl::MigrationOpEvent)
        end

        describe "can track invocations" do
          it "individually" do
            [LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW].each do |origin|
              tracker = subject.new(flag, context, detail, LaunchDarkly::Interfaces::Migrations::STAGE_LIVE)
              tracker.operation(LaunchDarkly::Interfaces::Migrations::OP_WRITE)
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
            expect(event.invoked.include?(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD)).to be true
            expect(event.invoked.include?(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW)).to be true
          end
        end

        it "can track consistency" do
          # TODO(uc2-migrations): Add additional tests once sampling is added
          [true, false].each do |expected_consistent|
            tracker = minimal_tracker
            tracker.consistent(-> { expected_consistent })
            event = tracker.build

            expect(event.consistency_check).to be expected_consistent
          end
        end

        describe "can track errors" do
          it "individually" do
            [LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW].each do |origin|
              tracker = minimal_tracker
              tracker.error(origin)

              event = tracker.build
              expect(event.errors.length).to eq(1)
              expect(event.errors.include?(origin)).to be true
            end
          end

          it "together" do
            tracker = minimal_tracker
            tracker.error(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD)
            tracker.error(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW)

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
            [LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW].each do |origin|
              tracker = minimal_tracker
              tracker.latency(origin, 5.4)

              event = tracker.build
              expect(event.latencies.length).to eq(1)
              expect(event.latencies[origin]).to eq(5.4)
            end
          end

          it "together" do
            tracker = minimal_tracker
            tracker.latency(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, 2)
            tracker.latency(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, 3)

            event = tracker.build
            expect(event.latencies.length).to be(2)
            expect(event.latencies[LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD]).to eq(2)
            expect(event.latencies[LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW]).to eq(3)
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
            tracker.latency(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, -1)
            tracker.latency(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, nil)

            event = tracker.build
            expect(event.latencies.length).to be(0)
          end
        end

        describe "can handle build failures" do
          it "without calling invoked" do
            tracker = subject.new(flag, context, detail, LaunchDarkly::Interfaces::Migrations::STAGE_LIVE)
            tracker.operation(LaunchDarkly::Interfaces::Migrations::OP_WRITE)

            event = tracker.build
            expect(event).to eq("no origins were invoked")
          end

          it "without operation" do
            tracker = subject.new(flag, context, detail, LaunchDarkly::Interfaces::Migrations::STAGE_LIVE)
            event = tracker.build
            expect(event).to eq("operation not provided")
          end

          it "with invalid context " do
            invalid = LaunchDarkly::LDContext.create({kind: 'multi', key: 'invalid'})
            tracker = subject.new(flag, invalid, detail, LaunchDarkly::Interfaces::Migrations::STAGE_LIVE)
            tracker.operation(LaunchDarkly::Interfaces::Migrations::OP_WRITE)
            tracker.invoked(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD)

            event = tracker.build
            expect(event).to eq("provided context was invalid")
          end
        end
      end
    end
  end
end
