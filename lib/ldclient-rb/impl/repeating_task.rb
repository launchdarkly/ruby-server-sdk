require "ldclient-rb/impl/util"

require "concurrent/atomic/event"
require "concurrent/atomics"

module LaunchDarkly
  module Impl
    class RepeatingTask
      attr_reader :name

      def initialize(interval, start_delay, task, logger, name)
        @interval = interval
        @start_delay = start_delay
        @task = task
        @logger = logger
        @stopped = Concurrent::AtomicBoolean.new(false)
        @stop_event = Concurrent::Event.new
        @worker = nil
        @name = name
      end

      def start
        @worker = Thread.new do
          @stop_event.wait(@start_delay) unless @start_delay.nil? || @start_delay == 0

          until @stopped.value do
            started_at = Time.now
            begin
              @task.call
            rescue => e
              Impl::Util.log_exception(@logger, "Uncaught exception from repeating task", e)
            end
            delta = @interval - (Time.now - started_at)
            @stop_event.wait(delta) if delta > 0
          end
        end

        @worker.name = @name
      end

      def stop
        if @stopped.make_true
          @stop_event.set # interrupts the worker if it is waiting between runs
          @worker.join if @worker && @worker.alive? && @worker != Thread.current
        end
      end
    end
  end
end
