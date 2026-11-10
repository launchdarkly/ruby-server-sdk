# frozen_string_literal: true

require "ldclient-rb/impl/data_source/status_provider"
require "ldclient-rb/impl/broadcaster"

require "timecop"

require "spec_helper"

module LaunchDarkly
  module Impl
    module DataSource
      describe StatusProviderV2 do
        let(:broadcaster) { double("broadcaster", broadcast: nil) }
        let(:valid) { LaunchDarkly::Interfaces::DataSource::Status::VALID }
        let(:interrupted) { LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED }
        let(:initializing) { LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING }

        def make_error
          LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
            LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN, 0, "boom", Time.now
          )
        end

        it "keeps the public state_since as a wall-clock time" do
          provider = StatusProviderV2.new(broadcaster)
          provider.update_status(valid, nil)

          expect(provider.status.state_since).to be_a(Time)
        end

        it "measures time in state on the monotonic clock and resets it on state change" do
          now = 1_000.0
          provider = StatusProviderV2.new(broadcaster, clock: -> { now })

          now = 1_030.0
          _, seconds = provider.status_and_seconds_in_state
          expect(seconds).to eq 30.0

          provider.update_status(valid, nil)
          status, seconds = provider.status_and_seconds_in_state
          expect(status.state).to eq valid
          expect(seconds).to eq 0.0

          now = 1_045.0
          _, seconds = provider.status_and_seconds_in_state
          expect(seconds).to eq 15.0
        end

        it "does not reset the duration when the state is unchanged" do
          now = 1_000.0
          provider = StatusProviderV2.new(broadcaster, clock: -> { now })
          provider.update_status(valid, nil)
          since = provider.status.state_since

          now = 1_020.0
          provider.update_status(valid, make_error)

          now = 1_050.0
          status, seconds = provider.status_and_seconds_in_state
          expect(status.state).to eq valid
          expect(status.state_since).to eq since
          expect(seconds).to eq 50.0
        end

        it "keeps both stamps when INTERRUPTED during INITIALIZING is coerced to INITIALIZING" do
          now = 1_000.0
          provider = StatusProviderV2.new(broadcaster, clock: -> { now })
          since = provider.status.state_since

          now = 1_030.0
          provider.update_status(interrupted, make_error)

          status, seconds = provider.status_and_seconds_in_state
          expect(status.state).to eq initializing
          expect(status.state_since).to eq since
          expect(seconds).to eq 30.0
        end

        it "keeps both stamps when a return to INITIALIZING is coerced to the current state" do
          now = 1_000.0
          provider = StatusProviderV2.new(broadcaster, clock: -> { now })
          provider.update_status(valid, nil)
          since = provider.status.state_since

          now = 1_030.0
          provider.update_status(initializing, make_error)

          status, seconds = provider.status_and_seconds_in_state
          expect(status.state).to eq valid
          expect(status.state_since).to eq since
          expect(seconds).to eq 30.0
        end

        it "ignores a nil state" do
          now = 1_000.0
          provider = StatusProviderV2.new(broadcaster, clock: -> { now })
          provider.update_status(valid, nil)
          since = provider.status.state_since

          now = 1_020.0
          provider.update_status(nil, make_error)

          status, seconds = provider.status_and_seconds_in_state
          expect(status.state).to eq valid
          expect(status.state_since).to eq since
          expect(seconds).to eq 20.0
        end

        describe "listeners" do
          let(:broadcaster) { LaunchDarkly::Impl::Broadcaster.new(SynchronousExecutor.new, $null_log) }
          let(:provider) { StatusProviderV2.new(broadcaster) }

          it "are called only when the status changes" do
            listener = ListenerSpy.new
            provider.add_listener(listener)

            provider.update_status(valid, nil)
            provider.update_status(valid, nil)
            expect(listener.statuses.map(&:state)).to eq([valid])

            provider.update_status(interrupted, nil)
            provider.update_status(interrupted, nil)
            expect(listener.statuses.map(&:state)).to eq([valid, interrupted])
          end

          it "are called when the state is the same but there is a new error" do
            listener = ListenerSpy.new
            provider.add_listener(listener)
            error = make_error

            provider.update_status(valid, nil)
            provider.update_status(valid, error)

            expect(listener.statuses.map(&:state)).to eq([valid, valid])
            expect(listener.statuses.last.last_error).to eq(error)
          end

          it "each get a single change" do
            listener1 = ListenerSpy.new
            listener2 = ListenerSpy.new
            provider.add_listener(listener1)
            provider.add_listener(listener2)

            provider.update_status(valid, nil)

            expect(listener1.statuses.map(&:state)).to eq([valid])
            expect(listener2.statuses.map(&:state)).to eq([valid])
          end
        end

        it "is unaffected by wall-clock steps" do
          provider = StatusProviderV2.new(broadcaster)
          provider.update_status(valid, nil)

          Timecop.freeze(Time.now + 3600) do
            _, seconds = provider.status_and_seconds_in_state
            expect(seconds).to be < 60
          end
        end
      end
    end
  end
end
