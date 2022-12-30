require "ldclient-rb/impl/repeating_task"

require "concurrent/atomics"

require "spec_helper"

module LaunchDarkly
  module Impl
    describe RepeatingTask do
      def null_logger
        double().as_null_object
      end

      it "does not start when created" do
        signal = Concurrent::Event.new
        task = RepeatingTask.new(0.01, 0, -> { signal.set }, null_logger)
        begin
          expect(signal.wait(0.1)).to be false
        ensure
          task.stop
        end
      end

      it "executes until stopped" do
        queue = Queue.new
        task = RepeatingTask.new(0.1, 0, -> { queue << Time.now }, null_logger)
        begin
          last = nil
          task.start
          3.times do
            time = queue.pop
            unless last.nil?
              expect(time.to_f - last.to_f).to be >=(0.05)
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
            expect(time.to_f).to be <=(stopped_time.to_f)
          rescue ThreadError
            no_more_items = true
            break
          end
        end
        expect(no_more_items).to be true
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
          null_logger)
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
