require "ldclient-rb/evaluation_detail"

# This file contains any pieces of low-level evaluation logic that don't need to be inside the Evaluator
# class, because they don't depend on any SDK state outside of their input parameters.

module LaunchDarkly
  module Impl
    module EvaluatorHelpers
      #
      # @param flag [LaunchDarkly::Impl::Model::FeatureFlag]
      # @param reason [LaunchDarkly::EvaluationReason]
      #
      def self.evaluation_detail_for_off_variation(flag, reason)
        index = flag.off_variation
        index.nil? ? EvaluationDetail.new(nil, nil, reason) : evaluation_detail_for_variation(flag, index, reason)
      end

      #
      # @param flag [LaunchDarkly::Impl::Model::FeatureFlag]
      # @param index [Integer]
      # @param reason [LaunchDarkly::EvaluationReason]
      #
      def self.evaluation_detail_for_variation(flag, index, reason)
        vars = flag.variations
        if index < 0 || index >= vars.length
          EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          # This error condition has already been logged at the time we received the flag data - see model/feature_flag.rb
        else
          EvaluationDetail.new(vars[index], index, reason)
        end
      end

      #
      # @param context [LaunchDarkly::LDContext]
      # @param kind [String, nil]
      # @param keys [Enumerable<String>]
      # @return [Boolean]
      #
      def self.context_key_in_target_list(context, kind, keys)
        return false unless keys.is_a? Enumerable
        return false if keys.empty?

        matched_context = context.individual_context(kind || LaunchDarkly::LDContext::KIND_DEFAULT)
        return false if matched_context.nil?

        keys.include? matched_context.key
      end
    end
  end
end
