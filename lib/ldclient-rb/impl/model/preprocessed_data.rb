require "ldclient-rb/impl/evaluator_helpers"

module LaunchDarkly
  module Impl
    module DataModelPreprocessing
      #
      # Container for a precomputed result that includes a specific variation index and value, an
      # evaluation reason, and optionally an alternate evaluation reason that corresponds to the
      # "in experiment" state.
      #
      class EvalResultsForSingleVariation
        def initialize(value, variation_index, regular_reason, in_experiment_reason = nil)
          @regular_result = EvaluationDetail.new(value, variation_index, regular_reason)
          @in_experiment_result = in_experiment_reason ?
            EvaluationDetail.new(value, variation_index, in_experiment_reason) :
            @regular_result
        end

        # @param in_experiment [Boolean] indicates whether we want the result to include
        #   "inExperiment: true" in the reason or not
        # @return [EvaluationDetail]
        def get_result(in_experiment = false)
          in_experiment ? @in_experiment_result : @regular_result
        end
      end

      #
      # Container for a set of precomputed results, one for each possible flag variation.
      #
      class EvalResultFactoryMultiVariations
        def initialize(variation_factories)
          @factories = variation_factories
        end

        # @param index [Integer] the variation index
        # @param in_experiment [Boolean] indicates whether we want the result to include
        #   "inExperiment: true" in the reason or not
        def for_variation(index, in_experiment)
          if index < 0 || index >= @factories.length
            EvaluationDetail.new(nil, nil, EvaluationReason.error(EvaluationReason::ERROR_MALFORMED_FLAG))
          else
            @factories[index].get_result(in_experiment)
          end
        end
      end

      # Base class for all of the preprocessed data classes we embed in our data model. Using this class
      # ensures that none of its properties will be included in JSON representations. It also overrides
      # == to say that it is always equal with another instance of the same class; equality tests on
      # this class are only ever done in test code, and we want the contents of these classes to be
      # ignored in test code unless we are looking at specific attributes.
      class PreprocessedDataBase
        def as_json(*)
          nil
        end

        def to_json(*a)
          "null"
        end

        def ==(other)
          other.class == self.class
        end
      end

      class FlagPreprocessed < PreprocessedDataBase
        def initialize(off_result, fallthrough_factory)
          super()
          @off_result = off_result
          @fallthrough_factory = fallthrough_factory
        end

        # @return [EvalResultsForSingleVariation]
        attr_reader :off_result
        # @return [EvalResultFactoryMultiVariations]
        attr_reader :fallthrough_factory
      end

      class PrerequisitePreprocessed < PreprocessedDataBase
        def initialize(failed_result)
          super()
          @failed_result = failed_result
        end

        # @return [EvalResultsForSingleVariation]
        attr_reader :failed_result
      end

      class TargetPreprocessed < PreprocessedDataBase
        def initialize(match_result)
          super()
          @match_result = match_result
        end

        # @return [EvalResultsForSingleVariation]
        attr_reader :match_result
      end

      class FlagRulePreprocessed < PreprocessedDataBase
        def initialize(all_match_results)
          super()
          @all_match_results = all_match_results
        end

        # @return [EvalResultsForSingleVariation]
        attr_reader :all_match_results
      end

      class Preprocessor
        def initialize(logger = nil)
          @logger = logger
        end

        def preprocess_item!(kind, item)
          if kind.eql? FEATURES
            preprocess_flag!(item)
          elsif kind.eql? SEGMENTS
            preprocess_segment!(item)
          end
        end

        def preprocess_all_items!(kind, items_map)
          return items_map unless items_map
          items_map.each do |key, item|
            preprocess_item!(kind, item)
          end
        end

        def preprocess_flag!(flag)
          flag[:_preprocessed] = FlagPreprocessed.new(
            EvaluatorHelpers.off_result(flag),
            precompute_multi_variation_results(flag, EvaluationReason::fallthrough(false), EvaluationReason::fallthrough(true))
          )
          (flag[:prerequisites] || []).each do |prereq|
            preprocess_prerequisite!(prereq, flag)
          end
          (flag[:targets] || []).each do |target|
            preprocess_target!(target, flag)
          end
          rules = flag[:rules]
          (rules || []).each_index do |index|
            preprocess_flag_rule!(rules[index], index, flag)
          end
        end

        def preprocess_segment!(segment)
          # nothing to do for segments currently
        end

        private def preprocess_prerequisite!(prereq, flag)
          prereq[:_preprocessed] = PrerequisitePreprocessed.new(
            EvaluatorHelpers.prerequisite_failed_result(prereq, flag, @logger)
          )
        end

        private def preprocess_target!(target, flag)
          target[:_preprocessed] = TargetPreprocessed.new(
            EvaluatorHelpers.target_match_result(target, flag, @logger)
          )
        end

        private def preprocess_flag_rule!(rule, index, flag)
          match_reason = EvaluationReason::rule_match(index, rule[:id])
          match_reason_in_experiment = EvaluationReason::rule_match(index, rule[:id], true)
          rule[:_preprocessed] = FlagRulePreprocessed.new(
            precompute_multi_variation_results(flag, match_reason, match_reason_in_experiment)
          )
        end

        private def precompute_multi_variation_results(flag, regular_reason, in_experiment_reason)
          factories = []
          vars = flag[:variations] || []
          vars.each_index do |index|
            factories << EvalResultsForSingleVariation.new(vars[index], index, regular_reason, in_experiment_reason)
          end
          EvalResultFactoryMultiVariations.new(factories)
        end
      end
    end
  end
end
