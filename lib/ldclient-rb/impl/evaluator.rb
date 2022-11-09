require "ldclient-rb/evaluation_detail"
require "ldclient-rb/impl/evaluator_bucketing"
require "ldclient-rb/impl/evaluator_helpers"
require "ldclient-rb/impl/evaluator_operators"
require "ldclient-rb/impl/model/feature_flag"
require "ldclient-rb/impl/model/segment"

module LaunchDarkly
  module Impl
    # Used internally to record that we evaluated a prerequisite flag.
    PrerequisiteEvalRecord = Struct.new(
      :prereq_flag,     # the prerequisite flag that we evaluated
      :prereq_of_flag,  # the flag that it was a prerequisite of
      :detail           # the EvaluationDetail representing the evaluation result
    )

    # Encapsulates the feature flag evaluation logic. The Evaluator has no knowledge of the rest of the SDK environment;
    # if it needs to retrieve flags or segments that are referenced by a flag, it does so through a simple function that
    # is provided in the constructor. It also produces feature requests as appropriate for any referenced prerequisite
    # flags, but does not send them.
    class Evaluator
      # A single Evaluator is instantiated for each client instance.
      #
      # @param get_flag [Function] called if the Evaluator needs to query a different flag from the one that it is
      #   currently evaluating (i.e. a prerequisite flag); takes a single parameter, the flag key, and returns the
      #   flag data - or nil if the flag is unknown or deleted
      # @param get_segment [Function] similar to `get_flag`, but is used to query a user segment.
      # @param logger [Logger] the client's logger
      def initialize(get_flag, get_segment, get_big_segments_membership, logger)
        @get_flag = get_flag
        @get_segment = get_segment
        @get_big_segments_membership = get_big_segments_membership
        @logger = logger
      end

      # Used internally to hold an evaluation result and additional state that may be accumulated during an
      # evaluation. It's simpler and a bit more efficient to represent these as mutable properties rather than
      # trying to use a pure functional approach, and since we're not exposing this object to any application code
      # or retaining it anywhere, we don't have to be quite as strict about immutability.
      #
      # The big_segments_status and big_segments_membership properties are not used by the caller; they are used
      # during an evaluation to cache the result of any Big Segments query that we've done for this user, because
      # we don't want to do multiple queries for the same user if multiple Big Segments are referenced in the same
      # evaluation.
      EvalResult = Struct.new(
        :detail,  # the EvaluationDetail representing the evaluation result
        :prereq_evals,  # an array of PrerequisiteEvalRecord instances, or nil
        :big_segments_status,
        :big_segments_membership
      )

      # Helper function used internally to construct an EvaluationDetail for an error result.
      def self.error_result(errorKind, value = nil)
        EvaluationDetail.new(value, nil, EvaluationReason.error(errorKind))
      end

      # The client's entry point for evaluating a flag. The returned `EvalResult` contains the evaluation result and
      # any events that were generated for prerequisite flags; its `value` will be `nil` if the flag returns the
      # default value. Error conditions produce a result with a nil value and an error reason, not an exception.
      #
      # @param flag [LaunchDarkly::Impl::Model::FeatureFlag] the flag
      # @param context [LaunchDarkly::LDContext] the evaluation context
      # @return [EvalResult] the evaluation result
      def evaluate(flag, context)
        result = EvalResult.new
        detail = eval_internal(flag, context, result)
        unless result.big_segments_status.nil?
          # If big_segments_status is non-nil at the end of the evaluation, it means a query was done at
          # some point and we will want to include the status in the evaluation reason.
          detail = EvaluationDetail.new(detail.value, detail.variation_index,
            detail.reason.with_big_segments_status(result.big_segments_status))
        end
        result.detail = detail
        result
      end

      # @param segment [LaunchDarkly::Impl::Model::Segment]
      def self.make_big_segment_ref(segment)  # method is visible for testing
        # The format of Big Segment references is independent of what store implementation is being
        # used; the store implementation receives only this string and does not know the details of
        # the data model. The Relay Proxy will use the same format when writing to the store.
        "#{segment.key}.g#{segment.generation}"
      end

      private

      # @param flag [LaunchDarkly::Impl::Model::FeatureFlag] the flag
      # @param context [LaunchDarkly::LDContext] the evaluation context
      # @param state [EvalResult]
      def eval_internal(flag, context, state)
        unless flag.on
          return flag.off_result
        end

        prereq_failure_result = check_prerequisites(flag, context, state)
        return prereq_failure_result unless prereq_failure_result.nil?

        # Check context target matches
        flag.targets.each do |target|
          target.values.each do |value|
            if value == context.key
              return target.match_result
            end
          end
        end

        # Check custom rules
        flag.rules.each do |rule|
          if rule_match_context(rule, context, state)
            return get_value_for_variation_or_rollout(flag, rule.variation_or_rollout, context, rule.match_results)
          end
        end

        # Check the fallthrough rule
        unless flag.fallthrough.nil?
          return get_value_for_variation_or_rollout(flag, flag.fallthrough, context, flag.fallthrough_results)
        end

        EvaluationDetail.new(nil, nil, EvaluationReason::fallthrough)
      end

      # @param flag [LaunchDarkly::Impl::Model::FeatureFlag] the flag
      # @param context [LaunchDarkly::LDContext] the evaluation context
      # @param state [EvalResult]
      def check_prerequisites(flag, context, state)
        flag.prerequisites.each do |prerequisite|
          prereq_ok = true
          prereq_key = prerequisite.key
          prereq_flag = @get_flag.call(prereq_key)

          if prereq_flag.nil?
            @logger.error { "[LDClient] Could not retrieve prerequisite flag \"#{prereq_key}\" when evaluating \"#{flag.key}\"" }
            prereq_ok = false
          else
            begin
              prereq_res = eval_internal(prereq_flag, context, state)
              # Note that if the prerequisite flag is off, we don't consider it a match no matter what its
              # off variation was. But we still need to evaluate it in order to generate an event.
              if !prereq_flag.on || prereq_res.variation_index != prerequisite.variation
                prereq_ok = false
              end
              prereq_eval = PrerequisiteEvalRecord.new(prereq_flag, flag, prereq_res)
              state.prereq_evals = [] if state.prereq_evals.nil?
              state.prereq_evals.push(prereq_eval)
            rescue => exn
              Util.log_exception(@logger, "Error evaluating prerequisite flag \"#{prereq_key}\" for flag \"#{flag.key}\"", exn)
              prereq_ok = false
            end
          end
          unless prereq_ok
            return prerequisite.failure_result
          end
        end
        nil
      end

      # @param rule [LaunchDarkly::Impl::Model::FlagRule]
      # @param context [LaunchDarkly::LDContext]
      # @param state [EvalResult]
      def rule_match_context(rule, context, state)
        rule.clauses.each do |clause|
          return false unless clause_match_context(clause, context, state)
        end

        true
      end

      # @param clause [LaunchDarkly::Impl::Model::Clause]
      # @param context [LaunchDarkly::LDContext]
      # @param state [EvalResult]
      def clause_match_context(clause, context, state)
        # In the case of a segment match operator, we check if the context is in any of the segments,
        # and possibly negate
        if clause.op == :segmentMatch
          result = clause.values.any? { |v|
            segment = @get_segment.call(v)
            !segment.nil? && segment_match_context(segment, context, state)
          }
          clause.negate ? !result : result
        else
          clause_match_context_no_segments(clause, context)
        end
      end

      # @param clause [LaunchDarkly::Impl::Model::Clause]
      # @param context_value [any]
      # @return [Boolean]
      private def match_any_clause_value(clause, context_value)
        op = clause.op
        clause.values.any? { |cv| EvaluatorOperators.apply(op, context_value, cv) }
      end

      # @param clause [LaunchDarkly::Impl::Model::Clause]
      # @param context [LaunchDarkly::LDContext]
      # @return [Boolean]
      private def clause_match_by_kind(clause, context)
        # If attribute is "kind", then we treat operator and values as a match
        # expression against a list of all individual kinds in the context.
        # That is, for a multi-kind context with kinds of "org" and "user", it
        # is a match if either of those strings is a match with Operator and
        # Values.

        (0...context.individual_context_count).each do |i|
          c = context.individual_context(i)
          if !c.nil? && match_any_clause_value(clause, c.kind)
            return true
          end
        end

        false
      end

      # @param clause [LaunchDarkly::Impl::Model::Clause]
      # @param context [LaunchDarkly::LDContext]
      # @return [Boolean]
      def clause_match_context_no_segments(clause, context)
        if clause.attribute == "kind"
          result = clause_match_by_kind(clause, context)
          return clause.negate ? !result : result
        end

        matched_context = context.individual_context(clause.context_kind || LaunchDarkly::LDContext::KIND_DEFAULT)
        return false if matched_context.nil?

        user_val = matched_context.get_value(clause.attribute)
        return false if user_val.nil?

        result = if user_val.is_a? Enumerable
          user_val.any? { |uv| match_any_clause_value(clause, uv) }
        else
          match_any_clause_value(clause, user_val)
        end
        clause.negate ? !result : result
      end

      # @param segment [LaunchDarkly::Impl::Model::Segment]
      # @param context [LaunchDarkly::LDContext]
      # @return [Boolean]
      def segment_match_context(segment, context, state)
        segment.unbounded ? big_segment_match_context(segment, context, state) : simple_segment_match_context(segment, context, true)
      end

      # @param segment [LaunchDarkly::Impl::Model::Segment]
      # @param context [LaunchDarkly::LDContext]
      # @return [Boolean]
      def big_segment_match_context(segment, context, state)
        unless segment.generation
          # Big segment queries can only be done if the generation is known. If it's unset,
          # that probably means the data store was populated by an older SDK that doesn't know
          # about the generation property and therefore dropped it from the JSON data. We'll treat
          # that as a "not configured" condition.
          state.big_segments_status = BigSegmentsStatus::NOT_CONFIGURED
          return false
        end
        unless state.big_segments_status
          result = @get_big_segments_membership.nil? ? nil : @get_big_segments_membership.call(context.key)
          if result
            state.big_segments_membership = result.membership
            state.big_segments_status = result.status
          else
            state.big_segments_membership = nil
            state.big_segments_status = BigSegmentsStatus::NOT_CONFIGURED
          end
        end
        segment_ref = Evaluator.make_big_segment_ref(segment)
        membership = state.big_segments_membership
        included = membership.nil? ? nil : membership[segment_ref]
        return included unless included.nil?
        simple_segment_match_context(segment, context, false)
      end

      # @param segment [LaunchDarkly::Impl::Model::Segment]
      # @param context [LaunchDarkly::LDContext]
      # @param use_includes_and_excludes [Boolean]
      # @return [Boolean]
      def simple_segment_match_context(segment, context, use_includes_and_excludes)
        if use_includes_and_excludes
          if EvaluatorHelpers.context_key_in_target_list(context, nil, segment.included)
            return true
          end

          segment.included_contexts.each do |target|
            if EvaluatorHelpers.context_key_in_target_list(context, target.context_kind, target.values)
              return true
            end
          end

          if EvaluatorHelpers.context_key_in_target_list(context, nil, segment.excluded)
            return false
          end

          segment.excluded_contexts.each do |target|
            if EvaluatorHelpers.context_key_in_target_list(context, target.context_kind, target.values)
              return false
            end
          end
        end

        segment.rules.each do |r|
          return true if segment_rule_match_context(r, context, segment.key, segment.salt)
        end

        false
      end

      # @param rule [LaunchDarkly::Impl::Model::SegmentRule]
      # @param context [LaunchDarkly::LDContext]
      # @param segment_key [String]
      # @param salt [String]
      # @return [Boolean]
      def segment_rule_match_context(rule, context, segment_key, salt)
        rule.clauses.each do |c|
          return false unless clause_match_context_no_segments(c, context)
        end

        # If the weight is absent, this rule matches
        return true unless rule.weight

        # All of the clauses are met. See if the user buckets in
        bucket = EvaluatorBucketing.bucket_context(context, rule.rollout_context_kind, segment_key, rule.bucket_by || "key", salt, nil)
        weight = rule.weight.to_f / 100000.0
        bucket.nil? || bucket < weight
      end

      private

      def get_value_for_variation_or_rollout(flag, vr, context, precomputed_results)
        index, in_experiment = EvaluatorBucketing.variation_index_for_context(flag, vr, context)
        if index.nil?
          @logger.error("[LDClient] Data inconsistency in feature flag \"#{flag.key}\": variation/rollout object with no variation or rollout")
          return Evaluator.error_result(EvaluationReason::ERROR_MALFORMED_FLAG)
        end
        precomputed_results.for_variation(index, in_experiment)
      end
    end
  end
end
