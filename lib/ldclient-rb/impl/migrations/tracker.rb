require "set"
require "ldclient-rb/impl/sampler"
require "logger"

module LaunchDarkly
  module Impl
    module Migrations
      class OpTracker
        include LaunchDarkly::Interfaces::Migrations::OpTracker

        #
        # @param logger [Logger] logger
        # @param key [string] key
        # @param flag [LaunchDarkly::Impl::Model::FeatureFlag] flag
        # @param context [LaunchDarkly::LDContext] context
        # @param detail [LaunchDarkly::EvaluationDetail] detail
        # @param default_stage [Symbol] default_stage
        #
        def initialize(logger, key, flag, context, detail, default_stage)
          @logger = logger
          @key = key
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

          # @type [Int]
          @consistent_ratio = @flag&.migration_settings&.check_ratio
          @consistent_ratio = 1 if @consistent_ratio.nil?

          # @type [Set<Symbol>]
          @errors = Set.new
          # @type [Hash<Symbol, Float>]
          @latencies = Hash.new
        end

        def operation(operation)
          return unless LaunchDarkly::Migrations::VALID_OPERATIONS.include? operation

          @mutex.synchronize do
            @operation = operation
          end
        end

        def invoked(origin)
          return unless LaunchDarkly::Migrations::VALID_ORIGINS.include? origin

          @mutex.synchronize do
            @invoked.add(origin)
          end
        end

        def consistent(is_consistent)
          @mutex.synchronize do
            if @sampler.sample(@consistent_ratio)
              begin
                @consistent = is_consistent.call
              rescue => e
                LaunchDarkly::Util.log_exception(@logger, "Exception raised during consistency check; failed to record measurement", e)
              end
            end
          end
        end

        def error(origin)
          return unless LaunchDarkly::Migrations::VALID_ORIGINS.include? origin

          @mutex.synchronize do
            @errors.add(origin)
          end
        end

        def latency(origin, duration)
          return unless LaunchDarkly::Migrations::VALID_ORIGINS.include? origin
          return unless duration.is_a? Numeric
          return if duration < 0

          @mutex.synchronize do
            @latencies[origin] = duration
          end
        end

        def build
          @mutex.synchronize do
            return "operation cannot contain an empty key" if @key.empty?
            return "operation not provided" if @operation.nil?
            return "no origins were invoked" if @invoked.empty?
            return "provided context was invalid" unless @context.valid?

            result = check_invoked_consistency
            return result unless result == true

            LaunchDarkly::Impl::MigrationOpEvent.new(
              LaunchDarkly::Impl::Util.current_time_millis,
              @context,
              @key,
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
          LaunchDarkly::Migrations::VALID_ORIGINS.each do |origin|
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
