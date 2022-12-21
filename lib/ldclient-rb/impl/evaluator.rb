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

    class EvaluationException < StandardError
      def initialize(msg, error_kind = EvaluationReason::ERROR_MALFORMED_FLAG)
        super(msg)
        @error_kind = error_kind
      end

      # @return [Symbol]
      attr_reader :error_kind
    end

    class InvalidReferenceException < EvaluationException
    end

    class EvaluatorState
      # @param original_flag [LaunchDarkly::Impl::Model::FeatureFlag]
      def initialize(original_flag)
        @prereq_stack = EvaluatorStack.new(original_flag.key)
        @segment_stack = EvaluatorStack.new(nil)
      end

      attr_reader :prereq_stack
      attr_reader :segment_stack
    end

    #
    # A helper class for managing cycle detection.
    #
    # Each time a method sees a new flag or segment, they can push that
    # object's key onto the stack. Once processing for that object has
    # finished, you can call pop to remove it.
    #
    # Because the most common use case would be a flag or segment without ANY
    # prerequisites, this stack has a small optimization in place-- the stack
    # is not created until absolutely necessary.
    #
    class EvaluatorStack
      # @param original [String, nil]
      def initialize(original)
        @original = original
        # @type [Array<String>, nil]
        @stack = nil
      end

      # @param key [String]
      def push(key)
        # No need to store the key if we already have a record in our instance
        # variable.
        return if @original == key

        # The common use case is that flags/segments won't have prereqs, so we
        # don't allocate the stack memory until we absolutely must.
        if @stack.nil?
          @stack = []
        end

        @stack.push(key)
      end

      def pop
        return if @stack.nil? || @stack.empty?
        @stack.pop
      end

      #
      # @param key [String]
      # @return [Boolean]
      #
      def include?(key)
        return true if key == @original
        return false if @stack.nil?

        @stack.include? key
      end
    end

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
      # @param get_segment [Function] similar to `get_flag`, but is used to query a context segment.
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
      # during an evaluation to cache the result of any Big Segments query that we've done for this context, because
      # we don't want to do multiple queries for the same context if multiple Big Segments are referenced in the same
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
        state = EvaluatorState.new(flag)

        result = EvalResult.new
        begin
          detail = eval_internal(flag, context, result, state)
        rescue EvaluationException => exn
          LaunchDarkly::Util.log_exception(@logger, "Unexpected error when evaluating flag #{flag.key}", exn)
          result.detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(exn.error_kind))
          return result
        rescue => exn
          LaunchDarkly::Util.log_exception(@logger, "Unexpected error when evaluating flag #{flag.key}", exn)
          result.detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_EXCEPTION))
          return result
        end

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

      # @param flag [LaunchDarkly::Impl::Model::FeatureFlag] the flag
      # @param context [LaunchDarkly::LDContext] the evaluation context
      # @param eval_result [EvalResult]
      # @param state [EvaluatorState]
      # @raise [EvaluationException]
      private def eval_internal(flag, context, eval_result, state)
        unless flag.on
          return flag.off_result
        end

        prereq_failure_result = check_prerequisites(flag, context, eval_result, state)
        return prereq_failure_result unless prereq_failure_result.nil?

        # Check context target matches
        target_result = check_targets(context, flag)
        return target_result unless target_result.nil?

        # Check custom rules
        flag.rules.each do |rule|
          if rule_match_context(rule, context, eval_result, state)
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
      # @param eval_result [EvalResult]
      # @param state [EvaluatorState]
      # @raise [EvaluationException] if a flag prereq cycle is detected
      private def check_prerequisites(flag, context, eval_result, state)
        return if flag.prerequisites.empty?

        state.prereq_stack.push(flag.key)

        begin
          flag.prerequisites.each do |prerequisite|
            prereq_ok = true
            prereq_key = prerequisite.key

            if state.prereq_stack.include?(prereq_key)
              raise LaunchDarkly::Impl::EvaluationException.new(
                "prerequisite relationship to \"#{prereq_key}\" caused a circular reference; this is probably a temporary condition due to an incomplete update"
              )
            end

            prereq_flag = @get_flag.call(prereq_key)

            if prereq_flag.nil?
              @logger.error { "[LDClient] Could not retrieve prerequisite flag \"#{prereq_key}\" when evaluating \"#{flag.key}\"" }
              prereq_ok = false
            else
              prereq_res = eval_internal(prereq_flag, context, eval_result, state)
              # Note that if the prerequisite flag is off, we don't consider it a match no matter what its
              # off variation was. But we still need to evaluate it in order to generate an event.
              if !prereq_flag.on || prereq_res.variation_index != prerequisite.variation
                prereq_ok = false
              end
              prereq_eval = PrerequisiteEvalRecord.new(prereq_flag, flag, prereq_res)
              eval_result.prereq_evals = [] if eval_result.prereq_evals.nil?
              eval_result.prereq_evals.push(prereq_eval)
            end

            unless prereq_ok
              return prerequisite.failure_result
            end
          end
        ensure
          state.prereq_stack.pop
        end

        nil
      end

      # @param rule [LaunchDarkly::Impl::Model::FlagRule]
      # @param context [LaunchDarkly::LDContext]
      # @param eval_result [EvalResult]
      # @param state [EvaluatorState]
      # @raise [InvalidReferenceException]
      private def rule_match_context(rule, context, eval_result, state)
        rule.clauses.each do |clause|
          return false unless clause_match_context(clause, context, eval_result, state)
        end

        true
      end

      # @param clause [LaunchDarkly::Impl::Model::Clause]
      # @param context [LaunchDarkly::LDContext]
      # @param eval_result [EvalResult]
      # @param state [EvaluatorState]
      # @raise [InvalidReferenceException]
      private def clause_match_context(clause, context, eval_result, state)
        # In the case of a segment match operator, we check if the context is in any of the segments,
        # and possibly negate
        if clause.op == :segmentMatch
          result = clause.values.any? { |v|
            if state.segment_stack.include?(v)
              raise LaunchDarkly::Impl::EvaluationException.new(
                "segment rule referencing segment \"#{v}\" caused a circular reference; this is probably a temporary condition due to an incomplete update"
              )
            end

            segment = @get_segment.call(v)
            !segment.nil? && segment_match_context(segment, context, eval_result, state)
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
      # @raise [InvalidReferenceException] Raised if the clause.attribute is an invalid reference
      private def clause_match_context_no_segments(clause, context)
        raise InvalidReferenceException.new(clause.attribute.error) unless clause.attribute.error.nil?

        if clause.attribute.depth == 1 && clause.attribute.component(0) == :kind
          result = clause_match_by_kind(clause, context)
          return clause.negate ? !result : result
        end

        matched_context = context.individual_context(clause.context_kind || LaunchDarkly::LDContext::KIND_DEFAULT)
        return false if matched_context.nil?

        context_val = matched_context.get_value_for_reference(clause.attribute)
        return false if context_val.nil?

        result = if context_val.is_a? Enumerable
          context_val.any? { |uv| match_any_clause_value(clause, uv) }
        else
          match_any_clause_value(clause, context_val)
        end
        clause.negate ? !result : result
      end

      # @param segment [LaunchDarkly::Impl::Model::Segment]
      # @param context [LaunchDarkly::LDContext]
      # @param eval_result [EvalResult]
      # @param state [EvaluatorState]
      # @return [Boolean]
      private def segment_match_context(segment, context, eval_result, state)
        return big_segment_match_context(segment, context, eval_result, state) if segment.unbounded

        simple_segment_match_context(segment, context, true, eval_result, state)
      end

      # @param segment [LaunchDarkly::Impl::Model::Segment]
      # @param context [LaunchDarkly::LDContext]
      # @param eval_result [EvalResult]
      # @param state [EvaluatorState]
      # @return [Boolean]
      private def big_segment_match_context(segment, context, eval_result, state)
        unless segment.generation
          # Big segment queries can only be done if the generation is known. If it's unset,
          # that probably means the data store was populated by an older SDK that doesn't know
          # about the generation property and therefore dropped it from the JSON data. We'll treat
          # that as a "not configured" condition.
          eval_result.big_segments_status = BigSegmentsStatus::NOT_CONFIGURED
          return false
        end

        matched_context = context.individual_context(segment.unbounded_context_kind)
        return false if matched_context.nil?

        membership = eval_result.big_segments_membership.nil? ? nil : eval_result.big_segments_membership[matched_context.key]

        if membership.nil?
          # Note that this query is just by key; the context kind doesn't matter because any given
          # Big Segment can only reference one context kind. So if segment A for the "user" kind
          # includes a "user" context with key X, and segment B for the "org" kind includes an "org"
          # context with the same key X, it is fine to say that the membership for key X is
          # segment A and segment B-- there is no ambiguity.
          result = @get_big_segments_membership.nil? ? nil : @get_big_segments_membership.call(matched_context.key)
          if result
            eval_result.big_segments_status = result.status

            membership = result.membership
            eval_result.big_segments_membership = {} if eval_result.big_segments_membership.nil?
            eval_result.big_segments_membership[matched_context.key] = membership
          else
            eval_result.big_segments_status = BigSegmentsStatus::NOT_CONFIGURED
          end
        end

        membership_result = nil
        unless membership.nil?
          segment_ref = Evaluator.make_big_segment_ref(segment)
          membership_result = membership.nil? ? nil : membership[segment_ref]
        end

        return membership_result unless membership_result.nil?
        simple_segment_match_context(segment, context, false, eval_result, state)
      end

      # @param segment [LaunchDarkly::Impl::Model::Segment]
      # @param context [LaunchDarkly::LDContext]
      # @param use_includes_and_excludes [Boolean]
      # @param state [EvaluatorState]
      # @return [Boolean]
      private def simple_segment_match_context(segment, context, use_includes_and_excludes, eval_result, state)
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

        rules = segment.rules
        state.segment_stack.push(segment.key) unless rules.empty?

        begin
          rules.each do |r|
            return true if segment_rule_match_context(r, context, segment.key, segment.salt, eval_result, state)
          end
        ensure
          state.segment_stack.pop
        end

        false
      end

      # @param rule [LaunchDarkly::Impl::Model::SegmentRule]
      # @param context [LaunchDarkly::LDContext]
      # @param segment_key [String]
      # @param salt [String]
      # @return [Boolean]
      # @raise [InvalidReferenceException]
      private def segment_rule_match_context(rule, context, segment_key, salt, eval_result, state)
        rule.clauses.each do |c|
          return false unless clause_match_context(c, context, eval_result, state)
        end

        # If the weight is absent, this rule matches
        return true unless rule.weight

        # All of the clauses are met. See if the user buckets in
        begin
          bucket = EvaluatorBucketing.bucket_context(context, rule.rollout_context_kind, segment_key, rule.bucket_by || "key", salt, nil)
        rescue InvalidReferenceException
          return false
        end

        weight = rule.weight.to_f / 100000.0
        bucket.nil? || bucket < weight
      end

      private def get_value_for_variation_or_rollout(flag, vr, context, precomputed_results)
        index, in_experiment = EvaluatorBucketing.variation_index_for_context(flag, vr, context)

        if index.nil?
          @logger.error("[LDClient] Data inconsistency in feature flag \"#{flag.key}\": variation/rollout object with no variation or rollout")
          return Evaluator.error_result(EvaluationReason::ERROR_MALFORMED_FLAG)
        end
        precomputed_results.for_variation(index, in_experiment)
      end

      # @param [LaunchDarkly::LDContext] context
      # @param [LaunchDarkly::Impl::Model::FeatureFlag] flag
      # @return [LaunchDarkly::EvaluationDetail, nil]
      private def check_targets(context, flag)
        targets = flag.targets
        context_targets = flag.context_targets

        if context_targets.empty?
          unless targets.empty?
            user_context = context.individual_context(LDContext::KIND_DEFAULT)
            return nil if user_context.nil?

            targets.each do |target|
              if target.values.include?(user_context.key) # rubocop:disable Performance/InefficientHashSearch
                return target.match_result
              end
            end
          end

          return nil
        end

        context_targets.each do |target|
          if target.kind == LDContext::KIND_DEFAULT
            user_context = context.individual_context(LDContext::KIND_DEFAULT)
            next if user_context.nil?

            user_key = user_context.key
            targets.each do |user_target|
              if user_target.variation == target.variation
                if user_target.values.include?(user_key) # rubocop:disable Performance/InefficientHashSearch
                  return target.match_result
                end
                break
              end
            end
          elsif EvaluatorHelpers.context_key_in_target_list(context, target.kind, target.values)
            return target.match_result
          end
        end

        nil
      end
    end
  end
end
