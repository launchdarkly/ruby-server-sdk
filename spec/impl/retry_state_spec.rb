require "ldclient-rb/impl/retry_state"

require "spec_helper"

module LaunchDarkly
  module Impl
    describe RetryState do
      # A random source with no jitter, so a delay is the computed value exactly.
      let(:no_jitter) { double("random", rand: 0.0) }
      let(:logger) { double.as_null_object }

      before { @now = 0.0 }
      let(:clock) { -> { @now } }

      def streaming(delay = 1, random: no_jitter)
        RetryState.for_streaming(delay, logger, clock: clock, random: random)
      end

      def polling(interval = 30, random: no_jitter)
        RetryState.for_polling(interval, logger, random: random)
      end

      def delays_after(state, *kinds)
        kinds.map do |kind|
          state.record_failure(kind)
          state.next_delay
        end
      end

      describe ".classify_http_status" do
        [400, 408, 429, 500, 502, 503, 504, 599].each do |status|
          it "classifies #{status} as normal" do
            expect(RetryState.classify_http_status(status)).to eq(:normal)
          end
        end

        [401, 403, 404, 405, 409, 410, 499].each do |status|
          it "classifies #{status} as unexpected" do
            expect(RetryState.classify_http_status(status)).to eq(:unexpected)
          end
        end
      end

      describe "streaming" do
        it "waits nothing before any failure" do
          expect(streaming.next_delay).to eq(0)
        end

        it "doubles the normal delay up to 30 seconds" do
          expect(delays_after(streaming, *[:normal] * 7)).to eq([1, 2, 4, 8, 16, 30, 30])
        end

        it "moves to the extended regime after an unexpected failure" do
          expect(delays_after(streaming, :unexpected, :unexpected, :unexpected, :unexpected, :unexpected, :unexpected))
            .to eq([300, 600, 1200, 2400, 3600, 3600])
        end

        it "starts the extended sequence over on the move, and keeps counting after it" do
          state = streaming
          expect(delays_after(state, :normal, :normal, :normal)).to eq([1, 2, 4])
          expect(delays_after(state, :unexpected, :unexpected)).to eq([300, 600])
        end

        it "keeps the extended bounds for a normal failure that follows" do
          state = streaming
          state.record_failure(:unexpected)
          expect(delays_after(state, :normal, :normal, :normal)).to eq([600, 1200, 2400])
        end

        it "uses a configured delay above the ceilings as the bounds" do
          expect(delays_after(streaming(600), :normal, :normal)).to eq([600, 600])
          expect(delays_after(streaming(7200), :unexpected, :unexpected)).to eq([7200, 7200])
        end

        it "does not reset before 60 seconds of health" do
          state = streaming
          state.record_failure(:unexpected)
          state.record_success
          @now += 59
          state.record_failure(:normal)
          expect(state.next_delay).to eq(600)
        end

        it "resets after 60 seconds of health, noticed at the next failure" do
          state = streaming
          state.record_failure(:unexpected)
          state.record_success
          @now += 60
          state.record_failure(:normal)
          expect(state.next_delay).to eq(1)
        end

        it "measures health from the first success, not the last" do
          state = streaming
          state.record_failure(:normal)
          state.record_failure(:normal)
          state.record_success
          @now += 30
          state.record_success
          @now += 30
          state.record_failure(:normal)
          expect(state.next_delay).to eq(1)
        end

        it "starts a new healthy stretch after a failure" do
          state = streaming
          state.record_failure(:normal)
          state.record_success
          @now += 50
          state.record_failure(:normal)
          state.record_success
          @now += 50
          state.record_failure(:normal)
          expect(state.next_delay).to eq(4)
        end

        it "waits nothing after a success" do
          state = streaming
          state.record_failure(:unexpected)
          state.record_success
          expect(state.next_delay).to eq(0)
        end

        it "survives a very long outage" do
          state = streaming(1.0)
          2000.times { state.record_failure(:normal) }
          expect(state.next_delay).to eq(30)
          2000.times { state.record_failure(:unexpected) }
          expect(state.next_delay).to eq(3600)
        end
      end

      describe "polling" do
        it "waits the poll interval before any outcome" do
          expect(polling.next_delay).to eq(30)
        end

        it "waits the poll interval after a normal failure" do
          expect(delays_after(polling, :normal, :normal, :normal)).to eq([30, 30, 30])
        end

        it "backs off in the extended regime after an unexpected failure" do
          expect(delays_after(polling, :unexpected, :unexpected, :unexpected, :unexpected, :unexpected, :unexpected))
            .to eq([300, 600, 1200, 2400, 3600, 3600])
        end

        it "restores the poll interval after one success" do
          state = polling
          state.record_failure(:unexpected)
          state.record_success
          expect(state.next_delay).to eq(30)
        end

        it "keeps the extended bounds after one success" do
          state = polling
          state.record_failure(:unexpected)
          state.record_success
          state.record_failure(:normal)
          expect(state.next_delay).to eq(600)
        end

        it "resets after two successes in a row" do
          state = polling
          state.record_failure(:unexpected)
          state.record_success
          state.record_success
          state.record_failure(:normal)
          expect(state.next_delay).to eq(30)
        end

        it "does not count successes across a failure" do
          state = polling
          state.record_failure(:unexpected)
          state.record_success
          state.record_failure(:normal)
          state.record_success
          state.record_failure(:normal)
          expect(state.next_delay).to eq(1200)
        end

        it "never waits less than the poll interval, even with the most jitter" do
          state = polling(3000, random: double("random", rand: 0.999))
          expect(delays_after(state, :normal, :unexpected, :unexpected)).to all(eq(3000))
        end

        it "uses a poll interval above the extended ceiling as every bound" do
          expect(delays_after(polling(7200), :unexpected, :unexpected, :normal)).to eq([7200, 7200, 7200])
        end
      end

      describe "jitter" do
        it "subtracts up to half of the delay" do
          state = streaming(random: double("random", rand: 0.5))
          expect(delays_after(state, :normal, :normal, :unexpected)).to eq([0.75, 1.5, 225.0])
        end

        it "stays within bounds for a real random source" do
          state = streaming(random: Random.new(1234))
          10.times { state.record_failure(:normal) }
          100.times do
            state.record_failure(:normal)
            expect(state.next_delay).to be_between(15, 30).inclusive
          end
        end
      end

      describe "invalid input" do
        [0, -1, Float::NAN, Float::INFINITY, -Float::INFINITY, nil, "5"].each do |value|
          it "uses the default reconnect delay for #{value.inspect} and warns" do
            expect(logger).to receive(:warn).once
            expect(delays_after(streaming(value), :normal)).to eq([Config.default_initial_reconnect_delay])
          end

          it "uses the default poll interval for #{value.inspect} and warns" do
            expect(logger).to receive(:warn).once
            state = polling(value)
            expect(state.next_delay).to eq(Config.default_poll_interval)
          end
        end

        it "does not warn for a valid value" do
          expect(logger).not_to receive(:warn)
          streaming(0.5)
          polling(60)
        end
      end
    end
  end
end
