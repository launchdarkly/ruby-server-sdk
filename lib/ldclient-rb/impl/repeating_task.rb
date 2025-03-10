require "ldclient-rb/util"

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
        @worker = nil
        @name = name
      end

      def start
        @worker = Thread.new do
          sleep(@start_delay) unless @start_delay.nil? || @start_delay == 0

          until @stopped.value do
            started_at = Time.now
            begin
              @task.call
            rescue => e
              LaunchDarkly::Util.log_exception(@logger, "Uncaught exception from repeating task", e)
            end
            delta = @interval - (Time.now - started_at)
            if delta > 0
              sleep(delta)
            end
          end
        end

        @worker.name = @name
      end

      def stop
        if @stopped.make_true
          if @worker && @worker.alive? && @worker != Thread.current
            @worker.run  # causes the thread to wake up if it's currently in a sleep
            @worker.join
          end
        end
      end
    end
  end
end
