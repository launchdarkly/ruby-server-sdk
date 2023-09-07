require 'set'

module LaunchDarkly
  module Impl
    class Event
      # @param timestamp [Integer]
      # @param context [LaunchDarkly::LDContext]
      def initialize(timestamp, context)
        @timestamp = timestamp
        @context = context
      end

      # @return [Integer]
      attr_reader :timestamp
      # @return [LaunchDarkly::LDContext]
      attr_reader :context
    end

    class EvalEvent < Event
      def initialize(timestamp, context, key, version = nil, variation = nil, value = nil, reason = nil, default = nil,
        track_events = false, debug_until = nil, prereq_of = nil)
        super(timestamp, context)
        @key = key
        @version = version
        @variation = variation
        @value = value
        @reason = reason
        @default = default
        # avoid setting rarely-used attributes if they have no value - this saves a little space per instance
        @track_events = track_events if track_events
        @debug_until = debug_until if debug_until
        @prereq_of = prereq_of if prereq_of
      end

      attr_reader :key
      attr_reader :version
      attr_reader :variation
      attr_reader :value
      attr_reader :reason
      attr_reader :default
      attr_reader :track_events
      attr_reader :debug_until
      attr_reader :prereq_of
    end

    class MigrationOpEvent < Event
      #
      # A migration op event represents the results of a migration-assisted read or write operation.
      #
      # The event includes optional measurements reporting on consistency checks, error reporting, and operation latency
      # values.
      #
      # @param timestamp [Integer]
      # @param context [LaunchDarkly::LDContext]
      # @param flag [LaunchDarkly::Impl::Model::FeatureFlag]
      # @param operation [Symbol]
      # @param default_stage [Symbol]
      # @param evaluation [LaunchDarkly::EvaluationDetail]
      # @param invoked [Set]
      # @param consistency_check [Boolean, nil]
      # @param errors [Set]
      # @param latencies [Hash<Symbol, Float>]
      #
      def initialize(timestamp, context, flag, operation, default_stage, evaluation, invoked, consistency_check, errors, latencies)
        super(timestamp, context)
        @operation = operation
        @flag_key = flag.key
        @default = default_stage
        @evaluation = evaluation
        @consistency_check = consistency_check
        @invoked = invoked
        @errors = errors
        @latencies = latencies
      end

      attr_reader :operation
      attr_reader :flag_key
      attr_reader :default
      attr_reader :evaluation
      attr_reader :consistency_check
      attr_reader :invoked
      attr_reader :errors
      attr_reader :latencies
    end

    class IdentifyEvent < Event
      def initialize(timestamp, context)
        super(timestamp, context)
      end
    end

    class CustomEvent < Event
      def initialize(timestamp, context, key, data = nil, metric_value = nil)
        super(timestamp, context)
        @key = key
        @data = data unless data.nil?
        @metric_value = metric_value unless metric_value.nil?
      end

      attr_reader :key
      attr_reader :data
      attr_reader :metric_value
    end

    class IndexEvent < Event
      def initialize(timestamp, context)
        super(timestamp, context)
      end
    end

    class DebugEvent < Event
      def initialize(eval_event)
        super(eval_event.timestamp, eval_event.context)
        @eval_event = eval_event
      end

      attr_reader :eval_event
    end
  end
end
