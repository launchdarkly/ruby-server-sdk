require "ldclient-rb/impl/repeating_task"

require "concurrent/atomics"

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
