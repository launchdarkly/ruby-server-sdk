require "set"
require "ldclient-rb/impl/sampler"

module LaunchDarkly
  module Impl
    module Migrations
      class OpTracker
        include LaunchDarkly::Interfaces::Migrations::OpTracker

        VALID_ORIGINS = [LaunchDarkly::Migrations::ORIGIN_OLD, LaunchDarkly::Migrations::ORIGIN_NEW]
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
          @sampler = LaunchDarkly::Impl::Sampler.new(Random.new)

          @mutex = Mutex.new

          # @type [Symbol, nil]
          @operation = nil

          # @type [Set<Symbol>]
          @invoked = Set.new
          # @type [Boolean, nil]
          @consistent = nil
          # @type [Int, nil]
          @consistent_ratio = @flag&.migration_settings&.check_ratio
          # @type [Set<Symbol>]
          @errors = Set.new
          # @type [Hash<Symbol, Float>]
          @latencies = Hash.new
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
            ratio = @flag.migration_settings&.check_ratio.nil? ? 1 : @flag.migration_settings.check_ratio
            if @sampler.sample(ratio)
              @consistent = is_consistent.call
            end
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

        def build
          @mutex.synchronize do
            return "flag not provided" if @flag.nil?
            return "operation not provided" if @operation.nil?
            return "no origins were invoked" if @invoked.empty?
            return "provided context was invalid" unless @context.valid?

            result = check_invoked_consistency
            return result unless result == true

            LaunchDarkly::Impl::MigrationOpEvent.new(
              LaunchDarkly::Impl::Util.current_time_millis,
              @context,
              @flag,
              @operation,
              @default_stage,
              @detail,
              @invoked,
              @consistent,
              @consistent_ratio,
              @errors,
              @latencies
            )
          end
        end

        private def check_invoked_consistency
          VALID_ORIGINS.each do |origin|
            next if @invoked.include? origin

            return "provided latency for origin '#{origin}' without recording invocation" if @latencies.include? origin
            return "provided error for origin '#{origin}' without recording invocation" if @errors.include? origin
          end

          return "provided consistency without recording both invocations" if !@consistent.nil? && @invoked.size != 2

          true
        end
      end
    end
  end
end
