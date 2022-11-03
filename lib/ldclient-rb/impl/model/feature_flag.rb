require "ldclient-rb/impl/evaluator_helpers"
require "ldclient-rb/impl/model/clause"

module LaunchDarkly
  module Impl
    module Model
      class FeatureFlag
        # @param data [Hash]
        # @param logger [Logger|nil]
        def initialize(data, logger = nil)
          raise ArgumentError, "expected hash but got #{data.class}" unless data.is_a?(Hash)
          @data = data
          @key = data[:key]
          @version = data[:version]
          @deleted = !!data[:deleted]
          return if @deleted
          @variations = data[:variations] || []
          @on = !!data[:on]
          @fallthrough = data[:fallthrough]
          @off_variation = data[:offVariation]
          @off_result = EvaluatorHelpers.evaluation_detail_for_off_variation(self, EvaluationReason::off, logger)
          @fallthrough_results = Preprocessor.precompute_multi_variation_results(self,
              EvaluationReason::fallthrough(false), EvaluationReason::fallthrough(true))
          @prerequisites = (data[:prerequisites] || []).map do |prereq_data|
            Prerequisite.new(prereq_data, self, logger)
          end
          @targets = (data[:targets] || []).map do |target_data|
            Target.new(target_data, self, logger)
          end
          @rules = (data[:rules] || []).map.with_index do |rule_data, index|
            FlagRule.new(rule_data, index, self)
          end
        end

        # @return [Hash]
        attr_reader :data
        # @return [String]
        attr_reader :key
        # @return [Integer]
        attr_reader :version
        # @return [Boolean]
        attr_reader :deleted
        # @return [Array]
        attr_reader :variations
        # @return [Boolean]
        attr_reader :on
        # @return [Integer|nil]
        attr_reader :off_variation
        # @return [Hash]
        attr_reader :fallthrough
        # @return [LaunchDarkly::EvaluationDetail]
        attr_reader :off_result
        # @return [LaunchDarkly::Impl::Model::EvalResultFactoryMultiVariations]
        attr_reader :fallthrough_results
        # @return [Array<LaunchDarkly::Impl::Model::Prerequisite>]
        attr_reader :prerequisites
        # @return [Array<LaunchDarkly::Impl::Model::Target>]
        attr_reader :targets
        # @return [Array<LaunchDarkly::Impl::Model::FlagRule>]
        attr_reader :rules

        # This method allows us to read properties of the object as if it's just a hash; we can remove it if we
        # migrate entirely to using attributes of the class
        def [](key)
          @data[key]
        end

        def ==(other)
          other.is_a?(FeatureFlag) && other.data == self.data
        end

        def as_json(*) # parameter is unused, but may be passed if we're using the json gem
          @data
        end

        # Same as as_json, but converts the JSON structure into a string.
        def to_json(*a)
          as_json.to_json(a)
        end
      end

      class Prerequisite
        def initialize(data, flag, logger)
          @data = data
          @key = data[:key]
          @variation = data[:variation]
          @failure_result = EvaluatorHelpers.evaluation_detail_for_off_variation(flag,
            EvaluationReason::prerequisite_failed(@key), logger)
        end

        # @return [Hash]
        attr_reader :data
        # @return [String]
        attr_reader :key
        # @return [Integer]
        attr_reader :variation
        # @return [LaunchDarkly::EvaluationDetail]
        attr_reader :failure_result

        def as_json
          @data
        end
      end

      class Target
        def initialize(data, flag, logger)
          @data = data
          @values = data[:values] || []
          @match_result = EvaluatorHelpers.evaluation_detail_for_variation(flag,
            data[:variation], EvaluationReason::target_match, logger)
        end

        # @return [Hash]
        attr_reader :data
        # @return [Array]
        attr_reader :values
        # @return [LaunchDarkly::EvaluationDetail]
        attr_reader :match_result

        # This method allows us to read properties of the object as if it's just a hash; we can remove it if we
        # migrate entirely to using attributes of the class
        def [](key)
          @data[key]
        end

        def as_json
          @data
        end
      end

      class FlagRule
        def initialize(data, rule_index, flag)
          @data = data
          @clauses = (data[:clauses] || []).map do |clause_data|
            Clause.new(clause_data)
          end
          rule_id = data[:id]
          match_reason = EvaluationReason::rule_match(rule_index, rule_id)
          match_reason_in_experiment = EvaluationReason::rule_match(rule_index, rule_id, true)
          @match_results = Preprocessor.precompute_multi_variation_results(flag, match_reason, match_reason_in_experiment)
        end

        # @return [Hash]
        attr_reader :data
        # @return [Array<LaunchDarkly::Impl::Model::Clause>]
        attr_reader :clauses
        # @return [LaunchDarkly::Impl::Model::EvalResultFactoryMultiVariations]
        attr_reader :match_results

        # This method allows us to read properties of the object as if it's just a hash; we can remove it if we
        # migrate entirely to using attributes of the class
        def [](key)
          @data[key]
        end

        def as_json
          @data
        end
      end

      # Clause is defined in its own file because clauses are used by both flags and segments
    end
  end
end
