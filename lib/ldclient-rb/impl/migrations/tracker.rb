require 'set'

module LaunchDarkly
  module Impl
    module Migrations
      class OpTracker
        include LaunchDarkly::Interfaces::Migrations::OpTracker

        VALID_ORIGINS = [LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW]
        private_constant :VALID_ORIGINS

        #
        # @param flag [LaunchDarkly::Impl::Model::FeatureFlag] flag
        # @param context [LaunchDarkly::LDContext] context
        # @param detail [LaunchDarkly::EvaluationDetail] detail
        # @param default_stage [Symbol] default_stage
        #
        def initialize(flag, context, detail, default_stage)
          @flag = flag
          @context = context
          @detail = detail
          @default_stage = default_stage

          @mutex = Mutex.new

          # @type [Symbol, nil]
          @operation = nil

          # @type [Set<Symbol>]
          @invoked = Set.new
          # @type [Boolean, nil]
          @consistent = nil
          # @type [Set<Symbol>]
          @errors = Set.new
          # @type [Hash<String, Float>]
          @latencies = {}
        end

        def operation(operation)
          @mutex.synchronize do
            @operation = operation
          end
        end

        def invoked(origin)
          return unless VALID_ORIGINS.include? origin

          @mutex.synchronize do
            @invoked.add(origin)
          end
        end

        def consistent(is_consistent)
          @mutex.synchronize do
            # TODO(uc2-migrations): Add consistent sampling ratio support
            @consistent = is_consistent.call
          end
        end

        def error(origin)
          return unless VALID_ORIGINS.include? origin

          @mutex.synchronize do
            @errors.add(origin)
          end
        end

        def latency(origin, duration)
          return unless VALID_ORIGINS.include? origin
          return unless duration.is_a? Numeric
          return if duration < 0

          @mutex.synchronize do
            @latencies[origin] = duration
          end
        end

        def build()
          @mutex.synchronize do
            return "flag not provided" if @flag.nil?
            return "operation not provided" if @operation.nil?
            return "no origins were invoked" if @invoked.empty?
            return "provided context was invalid" unless @context.valid?

            LaunchDarkly::Impl::MigrationOpEvent.new(
              LaunchDarkly::Impl::Util.current_time_millis,
              @context,
              @flag,
              @operation,
              @default_stage,
              @evaluation,
              @invoked,
              @consistent,
              @errors,
              @latencies
            )
          end
        end
      end
    end
  end
end
