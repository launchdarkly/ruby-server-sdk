require "ldclient-rb/impl/repeating_task"

require "concurrent/atomics"
require "timecop"

require "spec_helper"

module LaunchDarkly
  module Impl
    describe RepeatingTask do
      def null_logger
        double.as_null_object
      end

      it "can name the task" do
        signal = Concurrent::Event.new
        task = RepeatingTask.new(0.01, 0, -> { signal.set }, null_logger, "Junie B.")

        expect(task.name).to eq("Junie B.")
        task.stop
      end

      it "does not start when created" do
        signal = Concurrent::Event.new
        task = RepeatingTask.new(0.01, 0, -> { signal.set }, null_logger, "test")
        begin
          expect(signal.wait(0.1)).to be false
        ensure
          task.stop
        end
      end

      it "executes until stopped" do
        queue = Queue.new
        task = RepeatingTask.new(0.1, 0, -> { queue << Time.now }, null_logger, "test")
        begin
          last = nil
          task.start
          3.times do
            time = queue.pop
            unless last.nil?
              expect(time.to_f - last.to_f).to be >= 0.05
            end
            last = time
          end
        ensure
          task.stop
          stopped_time = Time.now
        end
        no_more_items = false
        2.times do
          begin
            time = queue.pop(true)
            expect(time.to_f).to be <= stopped_time.to_f
          rescue ThreadError
            no_more_items = true
            break
          end
        end
        expect(no_more_items).to be true
      end

      it "reads a callable interval after each run" do
        runs = Queue.new
        run_count = 0
        intervals = []
        interval = -> {
          intervals << run_count
          0.01
        }
        task = RepeatingTask.new(interval, 0, -> { run_count += 1; runs << run_count }, null_logger, "test")
        begin
          task.start
          3.times { runs.pop }
        ensure
          task.stop
        end
        expect(intervals.take(2)).to eq([1, 2])
      end

      [["a numeric", 0.1], ["a callable", -> { 0.1 }]].each do |desc, interval|
        it "starts #{desc} interval when the run returns" do
          ends = Queue.new
          starts = Queue.new
          task = RepeatingTask.new(interval, 0,
            -> {
              starts << Time.now
              sleep(0.1)
              ends << Time.now
            },
            null_logger, "test")
          begin
            task.start
            starts.pop
            first_end = ends.pop
            second_start = starts.pop
            expect(second_start - first_end).to be >= 0.09
          ensure
            task.stop
          end
        end
      end

      # Runs the task with a callable interval until it has run twice, and returns the gap between the runs.
      def gap_between_runs(interval, logger)
        run_times = Queue.new
        task = RepeatingTask.new(interval, 0, -> { run_times << Time.now }, logger, "test")
        begin
          task.start
          first = run_times.pop
          second = run_times.pop
          expect(task.instance_variable_get(:@worker).alive?).to be true
          second - first
        ensure
          task.stop
        end
      end

      it "has a fallback interval above zero" do
        expect(RepeatingTask::FALLBACK_INTERVAL).to be > 0
      end

      it "does not wait or log when a callable interval returns zero" do
        logger = double("logger").as_null_object
        stub_const("LaunchDarkly::Impl::RepeatingTask::FALLBACK_INTERVAL", 0.3)

        expect(gap_between_runs(-> { 0 }, logger)).to be < 0.2
        expect(logger).not_to have_received(:error)
        expect(logger).not_to have_received(:warn)
      end

      [
        ["raises", -> { raise "interval failure" }],
        ["returns nil", -> { nil }],
        ["returns a negative number", -> { -1 }],
        ["returns NaN", -> { Float::NAN }],
      ].each do |desc, interval|
        it "logs at error and waits the fallback interval when a callable interval #{desc}" do
          logger = double("logger").as_null_object
          stub_const("LaunchDarkly::Impl::RepeatingTask::FALLBACK_INTERVAL", 0.3)

          expect(gap_between_runs(interval, logger)).to be >= 0.25
          expect(logger).to have_received(:error).at_least(:once)
          expect(logger).not_to have_received(:warn)
        end
      end

      it "stops promptly when stopped during a long callable interval" do
        ran = Concurrent::Event.new
        task = RepeatingTask.new(-> { 1e20 }, 0, -> { ran.set }, null_logger, "test")
        begin
          task.start
          expect(ran.wait(1)).to be true
          sleep(0.05)
          expect(task.instance_variable_get(:@worker).alive?).to be true
          started_at = Time.now
          task.stop
          expect(Time.now - started_at).to be < 1
        ensure
          task.stop
        end
      end

      it "schedules the next run from the monotonic clock, unaffected by wall-clock steps" do
        runs = Queue.new
        stepped = false
        task = RepeatingTask.new(10, 0,
          -> {
            unless stepped
              stepped = true
              # Freeze before signaling the main thread. Cross-thread Timecop is
              # safe here only because #stop joins the worker, so this freeze
              # always completes before the ensure's Timecop.return below.
              Timecop.freeze(Time.now + 3600)
            end
            runs << :ran
          },
          null_logger, "test")
        begin
          task.start
          expect(runs.pop).to eq :ran
          # Before the monotonic fix, the forward wall step made the computed wait
          # negative, so the next run fired immediately instead of after the interval.
          sleep(0.3)
          expect(runs).to be_empty
        ensure
          task.stop
          Timecop.return
        end
      end

      it "stops promptly when stopped during a long start delay" do
        ran = Concurrent::Event.new
        task = RepeatingTask.new(10, 10, -> { ran.set }, null_logger, "test")
        task.start
        started_at = Time.now
        task.stop
        elapsed = Time.now - started_at

        expect(elapsed).to be < 1
        expect(ran.set?).to be false
      end

      it "stops promptly when stopped while waiting between runs" do
        ran = Concurrent::Event.new
        task = RepeatingTask.new(10, 0, -> { ran.set }, null_logger, "test")
        begin
          task.start
          expect(ran.wait(1)).to be true
          started_at = Time.now
          task.stop
          elapsed = Time.now - started_at

          expect(elapsed).to be < 1
        ensure
          task.stop
        end
      end

      it "can be stopped before it is started" do
        task = RepeatingTask.new(0.01, 0, -> {}, null_logger, "test")

        expect { task.stop }.not_to raise_error
      end

      it "does not run the task if stopped before it is started" do
        ran = Concurrent::Event.new
        task = RepeatingTask.new(0.01, 0, -> { ran.set }, null_logger, "test")
        task.stop
        task.start
        begin
          expect(ran.wait(0.1)).to be false
        ensure
          task.stop
        end
      end

      it "can be stopped more than once" do
        task = RepeatingTask.new(10, 0, -> {}, null_logger, "test")
        task.start
        task.stop

        expect { task.stop }.not_to raise_error
      end

      it "keeps running after the task raises an exception" do
        queue = Queue.new
        calls = 0
        task = RepeatingTask.new(0.01, 0,
          -> {
            calls += 1
            queue << calls
            raise "boom" if calls == 1
          },
          null_logger, "test")
        begin
          task.start
          expect(queue.pop).to eq(1)
          expect(queue.pop).to eq(2)
        ensure
          task.stop
        end
      end

      it "can be stopped from within the task" do
        counter = 0
        stopped = Concurrent::Event.new
        task = RepeatingTask.new(0.01, 0,
          -> {
            counter += 1
            if counter >= 2
              task.stop
              stopped.set
            end
          },
          null_logger, "test")
        begin
          task.start
          expect(stopped.wait(0.1)).to be true
          expect(counter).to be 2
          sleep(0.1)
          expect(counter).to be 2
        ensure
          task.stop
        end
      end
    end
  end
end
