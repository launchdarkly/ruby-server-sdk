require "ldclient-rb/impl/evaluator_helpers"
require "ldclient-rb/impl/model/clause"
require "set"

# See serialization.rb for implementation notes on the data model classes.

def check_variation_range(flag, errors_out, variation, description)
  unless flag.nil? || errors_out.nil? || variation.nil?
    if variation < 0 || variation >= flag.variations.length
      errors_out << "#{description} has invalid variation index"
    end
  end
end

module LaunchDarkly
  module Impl
    module Model
      class FeatureFlag
        # @param data [Hash]
        # @param logger [Logger|nil]
        def initialize(data, logger = nil)
          raise ArgumentError, "expected hash but got #{data.class}" unless data.is_a?(Hash)
          errors = []
          @data = data
          @key = data[:key]
          @version = data[:version]
          @deleted = !!data[:deleted]
          return if @deleted
          @variations = data[:variations] || []
          @on = !!data[:on]
          fallthrough = data[:fallthrough] || {}
          @fallthrough = VariationOrRollout.new(fallthrough[:variation], fallthrough[:rollout], self, errors, "fallthrough")
          @off_variation = data[:offVariation]
          check_variation_range(self, errors, @off_variation, "off variation")
          @prerequisites = (data[:prerequisites] || []).map do |prereq_data|
            Prerequisite.new(prereq_data, self, errors)
          end
          @targets = (data[:targets] || []).map do |target_data|
            Target.new(target_data, self, errors)
          end
          @context_targets = (data[:contextTargets] || []).map do |target_data|
            Target.new(target_data, self, errors)
          end
          @rules = (data[:rules] || []).map.with_index do |rule_data, index|
            FlagRule.new(rule_data, index, self, errors)
          end
          @salt = data[:salt]
          @off_result = EvaluatorHelpers.evaluation_detail_for_off_variation(self, EvaluationReason::off)
          @fallthrough_results = Preprocessor.precompute_multi_variation_results(self,
              EvaluationReason::fallthrough(false), EvaluationReason::fallthrough(true))
          unless logger.nil?
            errors.each do |message|
              logger.error("[LDClient] Data inconsistency in feature flag \"#{@key}\": #{message}")
            end
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
        # @return [LaunchDarkly::Impl::Model::VariationOrRollout]
        attr_reader :fallthrough
        # @return [LaunchDarkly::EvaluationDetail]
        attr_reader :off_result
        # @return [LaunchDarkly::Impl::Model::EvalResultFactoryMultiVariations]
        attr_reader :fallthrough_results
        # @return [Array<LaunchDarkly::Impl::Model::Prerequisite>]
        attr_reader :prerequisites
        # @return [Array<LaunchDarkly::Impl::Model::Target>]
        attr_reader :targets
        # @return [Array<LaunchDarkly::Impl::Model::Target>]
        attr_reader :context_targets
        # @return [Array<LaunchDarkly::Impl::Model::FlagRule>]
        attr_reader :rules
        # @return [String]
        attr_reader :salt

        # This method allows us to read properties of the object as if it's just a hash. Currently this is
        # necessary because some data store logic is still written to expect hashes; we can remove it once
        # we migrate entirely to using attributes of the class.
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
          as_json.to_json(*a)
        end
      end

      class Prerequisite
        def initialize(data, flag, errors_out = nil)
          @data = data
          @key = data[:key]
          @variation = data[:variation]
          @failure_result = EvaluatorHelpers.evaluation_detail_for_off_variation(flag,
            EvaluationReason::prerequisite_failed(@key))
          check_variation_range(flag, errors_out, @variation, "prerequisite")
        end

        # @return [Hash]
        attr_reader :data
        # @return [String]
        attr_reader :key
        # @return [Integer]
        attr_reader :variation
        # @return [LaunchDarkly::EvaluationDetail]
        attr_reader :failure_result
      end

      class Target
        def initialize(data, flag, errors_out = nil)
          @kind = data[:contextKind] || LDContext::KIND_DEFAULT
          @data = data
          @values = Set.new(data[:values] || [])
          @variation = data[:variation]
          @match_result = EvaluatorHelpers.evaluation_detail_for_variation(flag,
            data[:variation], EvaluationReason::target_match)
          check_variation_range(flag, errors_out, @variation, "target")
        end

        # @return [String]
        attr_reader :kind
        # @return [Hash]
        attr_reader :data
        # @return [Set]
        attr_reader :values
        # @return [Integer]
        attr_reader :variation
        # @return [LaunchDarkly::EvaluationDetail]
        attr_reader :match_result
      end

      class FlagRule
        def initialize(data, rule_index, flag, errors_out = nil)
          @data = data
          @clauses = (data[:clauses] || []).map do |clause_data|
            Clause.new(clause_data, errors_out)
          end
          @variation_or_rollout = VariationOrRollout.new(data[:variation], data[:rollout], flag, errors_out, 'rule')
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
        # @return [LaunchDarkly::Impl::Model::VariationOrRollout]
        attr_reader :variation_or_rollout
      end

      class VariationOrRollout
        def initialize(variation, rollout_data, flag = nil, errors_out = nil, description = nil)
          @variation = variation
          check_variation_range(flag, errors_out, variation, description)
          @rollout = rollout_data.nil? ? nil : Rollout.new(rollout_data, flag, errors_out, description)
        end

        # @return [Integer|nil]
        attr_reader :variation
        # @return [Rollout|nil] currently we do not have a model class for the rollout
        attr_reader :rollout
      end

      class Rollout
        def initialize(data, flag = nil, errors_out = nil, description = nil)
          @context_kind = data[:contextKind]
          @variations = (data[:variations] || []).map { |v| WeightedVariation.new(v, flag, errors_out, description) }
          @bucket_by = data[:bucketBy]
          @kind = data[:kind]
          @is_experiment = @kind == "experiment"
          @seed = data[:seed]
        end

        # @return [String|nil]
        attr_reader :context_kind
        # @return [Array<WeightedVariation>]
        attr_reader :variations
        # @return [String|nil]
        attr_reader :bucket_by
        # @return [String|nil]
        attr_reader :kind
        # @return [Boolean]
        attr_reader :is_experiment
        # @return [Integer|nil]
        attr_reader :seed
      end

      class WeightedVariation
        def initialize(data, flag = nil, errors_out = nil, description = nil)
          @variation = data[:variation]
          @weight = data[:weight]
          @untracked = !!data[:untracked]
          check_variation_range(flag, errors_out, @variation, description)
        end

        # @return [Integer]
        attr_reader :variation
        # @return [Integer]
        attr_reader :weight
        # @return [Boolean]
        attr_reader :untracked
      end

      # Clause is defined in its own file because clauses are used by both flags and segments
    end
  end
end
