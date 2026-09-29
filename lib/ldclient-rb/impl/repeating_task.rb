require "ldclient-rb/impl/util"

require "concurrent/atomics"

module LaunchDarkly
  module Impl
    #
    # Runs a task again and again on a worker thread, with a fixed interval
    # between runs.
    #
    # The worker waits on an event instead of calling `sleep`, so `stop` can
    # wake it at once even if `stop` runs before the worker starts waiting.
    #
    # @private
    #
    class RepeatingTask
      attr_reader :name

      #
      # @param interval [Numeric] seconds between the start of one run and the start of the next
      # @param start_delay [Numeric, nil] seconds to wait before the first run
      # @param task [Proc] the code to run
      # @param logger [Logger]
      # @param name [String] the name given to the worker thread
      #
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

      #
      # Stops the worker thread and waits for it to finish.
      #
      # This method is safe to call more than once, before `start`, and from
      # inside the task itself.
      #
      def stop
        if @stopped.make_true
          @stop_event.set
          if @worker && @worker.alive? && @worker != Thread.current
            @worker.join
          end
        end
      end
    end
  end
end
