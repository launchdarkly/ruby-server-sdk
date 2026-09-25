module LaunchDarkly
  module Impl
    #
    # Computes how long to wait before a failed operation is tried again.
    #
    # Each failure is `:normal` or `:unexpected`. After a normal failure, the wait starts at the normal
    # initial delay and doubles with each failure, up to the normal ceiling. An unexpected failure moves
    # the state to the extended regime: the wait starts at the extended initial delay and doubles up to
    # the extended ceiling. The extended bounds stay in place until the reset policy is satisfied, so a
    # normal failure that follows cannot lower them. When the policy is satisfied, the state returns to
    # the normal regime and the delay sequence starts over.
    #
    # A random jitter of up to half of each delay is subtracted, so that many callers do not all try
    # again at the same moment. The wait never falls below the operating cadence.
    #
    # After each outcome, call {#record_failure} or {#record_success}, then read {#next_delay} for the
    # wait before the next operation. An instance is not thread-safe.
    #
    # @private
    #
    class RetryState
      # The longest normal delay for streaming, in seconds.
      NORMAL_STREAMING_CEILING_DELAY = 30

      # The delay bounds of the extended regime, in seconds.
      EXTENDED_INITIAL_DELAY = 5 * 60
      EXTENDED_CEILING_DELAY = 60 * 60

      # How long a stream must operate without a failure before its retry state resets, in seconds.
      STREAMING_RESET_INTERVAL = 60

      # How many polls in a row must succeed before polling's retry state resets.
      POLLING_RESET_SUCCESSES = 2

      # The longest wait a caller should pass to `Concurrent::Event#wait`, in seconds. A much longer
      # wait raises `RangeError`. This is about 31 years, so the bound has no effect in practice.
      MAX_WAIT = 1_000_000_000

      # The 4xx statuses that are still normal failures. Every other 4xx is unexpected.
      NORMAL_4XX_STATUSES = [400, 408, 429].freeze
      private_constant :NORMAL_4XX_STATUSES

      MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      private_constant :MONOTONIC_CLOCK

      #
      # Classifies an HTTP status.
      #
      # `400`, `408`, `429` and every `5xx` are normal. Every other `4xx`, including `401` and `403`,
      # is unexpected.
      #
      # @param status [Integer]
      # @return [Symbol] `:normal` or `:unexpected`
      #
      def self.classify_http_status(status)
        if status >= 400 && status < 500 && !NORMAL_4XX_STATUSES.include?(status)
          :unexpected
        else
          :normal
        end
      end

      #
      # Builds the retry state for a streaming data source.
      #
      # A healthy stream never waits, so the operating cadence is zero. A delay that is not a
      # positive, finite number is replaced by the default. A delay longer than a ceiling raises that
      # ceiling.
      #
      # @param initial_reconnect_delay [Numeric] seconds
      # @param logger [Logger]
      # @param clock [#call] returns monotonic seconds
      # @param random [#rand] returns a Float in [0, 1)
      # @return [RetryState]
      #
      def self.for_streaming(initial_reconnect_delay, logger, clock: MONOTONIC_CLOCK, random: Random.new)
        delay = usable_delay(initial_reconnect_delay, Config.default_initial_reconnect_delay, "initial_reconnect_delay", logger)
        new(
          normal_initial_delay: delay,
          normal_ceiling_delay: NORMAL_STREAMING_CEILING_DELAY,
          extended_initial_delay: [EXTENDED_INITIAL_DELAY, delay].max,
          extended_ceiling_delay: EXTENDED_CEILING_DELAY,
          reset_policy: AfterHealthyFor.new(STREAMING_RESET_INTERVAL, clock),
          operating_cadence: 0,
          random: random
        )
      end

      #
      # Builds the retry state for a polling data source.
      #
      # The poll interval is both the operating cadence and the normal ceiling, so a normal failure
      # waits the interval. An interval that is not a positive, finite number is replaced by the
      # default. No wait is shorter than the interval, so the interval wins over the extended ceiling.
      #
      # @param poll_interval [Numeric] seconds
      # @param logger [Logger]
      # @param random [#rand] returns a Float in [0, 1)
      # @return [RetryState]
      #
      def self.for_polling(poll_interval, logger, random: Random.new)
        interval = usable_delay(poll_interval, Config.default_poll_interval, "poll_interval", logger)
        new(
          normal_initial_delay: interval,
          normal_ceiling_delay: interval,
          extended_initial_delay: [EXTENDED_INITIAL_DELAY, interval].max,
          extended_ceiling_delay: EXTENDED_CEILING_DELAY,
          reset_policy: AfterConsecutiveSuccesses.new(POLLING_RESET_SUCCESSES),
          operating_cadence: interval,
          random: random
        )
      end

      private_class_method def self.usable_delay(value, default, name, logger)
        return value if value.is_a?(Numeric) && value.real? && value > 0 && value.finite?

        logger.warn { "[LDClient] #{name} must be a positive, finite number of seconds; using the default of #{default}s" }
        default
      end

      #
      # @param normal_initial_delay [Numeric] the first normal delay, in seconds
      # @param normal_ceiling_delay [Numeric] the longest normal delay, in seconds
      # @param extended_initial_delay [Numeric] the first extended delay, in seconds
      # @param extended_ceiling_delay [Numeric] the longest extended delay, in seconds
      # @param reset_policy [AfterHealthyFor, AfterConsecutiveSuccesses] decides when the state resets
      # @param operating_cadence [Numeric] the wait between healthy operations, in seconds; no wait is
      #   shorter than this
      # @param random [#rand] returns a Float in [0, 1)
      #
      def initialize(normal_initial_delay:, normal_ceiling_delay:, extended_initial_delay:, extended_ceiling_delay:,
        reset_policy:, operating_cadence: 0, random: Random.new)
        @normal_initial_delay = normal_initial_delay
        @normal_ceiling_delay = normal_ceiling_delay
        @extended_initial_delay = extended_initial_delay
        @extended_ceiling_delay = extended_ceiling_delay
        @reset_policy = reset_policy
        @operating_cadence = operating_cadence
        @random = random

        @attempts = 0
        @extended = false
        @min_delay = @normal_initial_delay
        @max_delay = [@normal_ceiling_delay, @normal_initial_delay].max
        @next_delay = @operating_cadence
      end

      #
      # @return [Numeric] the wait before the next operation, in seconds, as the last recorded
      #   outcome decided it
      #
      attr_reader :next_delay

      #
      # Records a failed attempt and decides the wait before the next one.
      #
      # @param kind [Symbol] `:normal` or `:unexpected`
      # @return [void]
      #
      def record_failure(kind)
        # A caller can record nothing while it is healthy, so a time-based reset can only be noticed here.
        reset_if_due
        @reset_policy.note_failure

        if kind == :unexpected && !@extended
          # Only the move to the extended regime starts the sequence over. A later unexpected failure
          # keeps counting up.
          @extended = true
          @min_delay = @extended_initial_delay
          @max_delay = [@extended_ceiling_delay, @min_delay].max
          @attempts = 1
        else
          @attempts += 1
        end

        # Integer exponentiation does not overflow, and a Float product that becomes Infinity is
        # still cut down to the ceiling.
        delay = [@min_delay * (2**(@attempts - 1)), @max_delay].min
        jitter = @random.rand * delay / 2
        @next_delay = [delay - jitter, @operating_cadence].max
      end

      #
      # Records a successful operation, and resets the retry state if the reset policy is satisfied.
      #
      # The next wait returns to the operating cadence even when the state has not reset, because a
      # backoff delay applies to a retry and not to every operation.
      #
      # @return [void]
      #
      def record_success
        @reset_policy.note_healthy
        reset_if_due
        @next_delay = @operating_cadence
      end

      private def reset_if_due
        return unless @reset_policy.satisfied?

        @attempts = 0
        @extended = false
        @min_delay = @normal_initial_delay
        @max_delay = [@normal_ceiling_delay, @normal_initial_delay].max
      end

      #
      # Resets once the component has operated without a failure for a number of seconds.
      #
      # @private
      #
      class AfterHealthyFor
        #
        # @param seconds [Numeric]
        # @param clock [#call] returns monotonic seconds
        #
        def initialize(seconds, clock)
          @healthy_seconds = seconds
          @clock = clock
          @healthy_since = nil
        end

        # A later call during the same healthy stretch does not move its start.
        def note_healthy
          @healthy_since = @clock.call if @healthy_since.nil?
        end

        def note_failure
          @healthy_since = nil
        end

        def satisfied?
          !@healthy_since.nil? && @clock.call - @healthy_since >= @healthy_seconds
        end
      end

      #
      # Resets once a number of operations in a row have succeeded.
      #
      # @private
      #
      class AfterConsecutiveSuccesses
        #
        # @param count [Integer]
        #
        def initialize(count)
          @count = count
          @successes = 0
        end

        def note_healthy
          @successes += 1
        end

        def note_failure
          @successes = 0
        end

        def satisfied?
          @successes >= @count
        end
      end
    end
  end
end
