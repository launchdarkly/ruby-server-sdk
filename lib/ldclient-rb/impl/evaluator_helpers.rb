require "ldclient-rb/evaluation_detail"

# This file contains any pieces of low-level evaluation logic that don't need to be inside the Evaluator
# class, because they don't depend on any SDK state outside of their input parameters.

module LaunchDarkly
  module Impl
    module EvaluatorHelpers
      def self.off_result(flag, logger = nil)
        pre = flag[:_preprocessed]
        pre ? pre.off_result : evaluation_detail_for_off_variation(flag, EvaluationReason::off, logger)
      end

      def self.target_match_result(target, flag, logger = nil)
        pre = target[:_preprocessed]
        pre ? pre.match_result : evaluation_detail_for_variation(
          flag, target[:variation], EvaluationReason::target_match, logger)
      end

      def self.prerequisite_failed_result(prereq, flag, logger = nil)
        pre = prereq[:_preprocessed]
        pre ? pre.failed_result : evaluation_detail_for_off_variation(
          flag, EvaluationReason::prerequisite_failed(prereq[:key]), logger
        )
      end

      def self.fallthrough_precomputed_results(flag)
        pre = flag[:_preprocessed]
        pre ? pre.fallthrough_factory : nil
      end

      def self.rule_precomputed_results(rule)
        pre = rule[:_preprocessed]
        pre ? pre.all_match_results : nil
      end

      def self.evaluation_detail_for_off_variation(flag, reason, logger = nil)
        index = flag[:offVariation]
        index.nil? ? EvaluationDetail.new(nil, nil, reason) : evaluation_detail_for_variation(flag, index, reason, logger)
      end

      def self.evaluation_detail_for_variation(flag, index, reason, logger = nil)
        vars = flag[:variations] || []
        if index < 0 || index >= vars.length
          logger.error("[LDClient] Data inconsistency in feature flag \"#{flag[:key]}\": invalid variation index") unless logger.nil?
          EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
        else
          EvaluationDetail.new(vars[index], index, reason)
        end
      end

      #
      # @param context [LaunchDarkly::LDContext]
      # @param kind [String, nil]
      # @param keys [Array<String>]
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
