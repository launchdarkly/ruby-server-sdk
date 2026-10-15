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
      # The wait, in seconds, when a callable interval raises or returns a value that is not a positive
      # number. It is long enough to stop a busy loop and short enough not to stall the task for long.
      FALLBACK_INTERVAL = 1

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
            delay = next_delay
            @stop_event.wait([delay, RetryState::MAX_WAIT].min) if delay > 0
          end
        end

        @worker.name = @name
      end

      private def next_delay
        return @interval if @interval.is_a?(Numeric)

        delay = @interval.call
        return delay if delay.is_a?(Numeric) && delay > 0

        @logger.warn { "[LDClient] Repeating task #{@name} got an invalid interval #{delay.inspect}; waiting #{FALLBACK_INTERVAL}s" }
        FALLBACK_INTERVAL
      rescue => e
        Impl::Util.log_exception(@logger, "Exception while reading the interval of repeating task #{@name}", e)
        FALLBACK_INTERVAL
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
