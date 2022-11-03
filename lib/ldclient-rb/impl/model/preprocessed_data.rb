require "ldclient-rb/impl/evaluator_helpers"

module LaunchDarkly
  module Impl
    module Model
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
        # @return [LaunchDarkly::EvaluationDetail]
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
        # @return [LaunchDarkly::EvaluationDetail]
        def for_variation(index, in_experiment)
          if index < 0 || index >= @factories.length
            EvaluationDetail.new(nil, nil, EvaluationReason.error(EvaluationReason::ERROR_MALFORMED_FLAG))
          else
            @factories[index].get_result(in_experiment)
          end
        end
      end

      class Preprocessor
        # @param flag [LaunchDarkly::Impl::Model::FeatureFlag]
        # @param regular_reason [LaunchDarkly::EvaluationReason]
        # @param in_experiment_reason [LaunchDarkly::EvaluationReason]
        # @return [EvalResultFactoryMultiVariations]
        def self.precompute_multi_variation_results(flag, regular_reason, in_experiment_reason)
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
