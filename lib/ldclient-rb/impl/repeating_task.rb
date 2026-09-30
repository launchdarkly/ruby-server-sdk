require "ldclient-rb/impl/retry_state"
require "ldclient-rb/impl/util"

require "concurrent/atomics"

module LaunchDarkly
  module Impl
    #
    # Runs a task again and again on a worker thread.
    #
    # The interval is read after each run, and the wait starts when the run
    # returns.
    #
    # The worker waits on an event instead of calling `sleep`, so `stop` can
    # wake it at once even if `stop` runs before the worker starts waiting.
    #
    # @private
    #
    class RepeatingTask
      attr_reader :name

      #
      # @param interval [Numeric, #call] seconds between runs, or an object that returns them
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
            begin
              @task.call
            rescue => e
              Impl::Util.log_exception(@logger, "Uncaught exception from repeating task", e)
            end
            delay = @interval.respond_to?(:call) ? @interval.call : @interval
            @stop_event.wait([delay, RetryState::MAX_WAIT].min) if delay > 0
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
