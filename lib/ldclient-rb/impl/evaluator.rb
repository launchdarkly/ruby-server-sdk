require "ldclient-rb/evaluation_detail"
require "ldclient-rb/impl/evaluator_bucketing"
require "ldclient-rb/impl/evaluator_operators"

module LaunchDarkly
  module Impl
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
      def initialize(get_flag, get_segment, logger)
        @get_flag = get_flag
        @get_segment = get_segment
        @logger = logger
      end

      # Used internally to hold an evaluation result and the events that were generated from prerequisites. The
      # `detail` property is an EvaluationDetail. The `events` property can be either an array of feature request
      # events or nil.
      EvalResult = Struct.new(:detail, :events)

      # Helper function used internally to construct an EvaluationDetail for an error result.
      def self.error_result(errorKind, value = nil)
        EvaluationDetail.new(value, nil, EvaluationReason.error(errorKind))
      end

      # The client's entry point for evaluating a flag. The returned `EvalResult` contains the evaluation result and
      # any events that were generated for prerequisite flags; its `value` will be `nil` if the flag returns the
      # default value. Error conditions produce a result with a nil value and an error reason, not an exception.
      #
      # @param flag [Object] the flag
      # @param user [Object] the user properties
      # @param event_factory [EventFactory] called to construct a feature request event when a prerequisite flag is
      #   evaluated; the caller is responsible for constructing the feature event for the top-level evaluation
      # @return [EvalResult] the evaluation result 
      def evaluate(flag, user, event_factory)
        if user.nil? || user[:key].nil?
          return EvalResult.new(Evaluator.error_result(EvaluationReason::ERROR_USER_NOT_SPECIFIED), [])
        end

        # If the flag doesn't have any prerequisites (which most flags don't) then it cannot generate any feature
        # request events for prerequisites and we can skip allocating an array.
        if flag[:prerequisites] && !flag[:prerequisites].empty?
          events = []
        else
          events = nil
        end

        detail = eval_internal(flag, user, events, event_factory)
        return EvalResult.new(detail, events.nil? || events.empty? ? nil : events)
      end

      private
      
      def eval_internal(flag, user, events, event_factory)
        if !flag[:on]
          return get_off_value(flag, EvaluationReason::off)
        end

        prereq_failure_reason = check_prerequisites(flag, user, events, event_factory)
        if !prereq_failure_reason.nil?
          return get_off_value(flag, prereq_failure_reason)
        end

        # Check user target matches
        (flag[:targets] || []).each do |target|
          (target[:values] || []).each do |value|
            if value == user[:key]
              return get_variation(flag, target[:variation], EvaluationReason::target_match)
            end
          end
        end
      
        # Check custom rules
        rules = flag[:rules] || []
        rules.each_index do |i|
          rule = rules[i]
          if rule_match_user(rule, user)
            reason = rule[:_reason]  # try to use cached reason for this rule
            reason = EvaluationReason::rule_match(i, rule[:id]) if reason.nil?
            return get_value_for_variation_or_rollout(flag, rule, user, reason)
          end
        end

        # Check the fallthrough rule
        if !flag[:fallthrough].nil?
          return get_value_for_variation_or_rollout(flag, flag[:fallthrough], user, EvaluationReason::fallthrough)
        end

        return EvaluationDetail.new(nil, nil, EvaluationReason::fallthrough)
      end

      def check_prerequisites(flag, user, events, event_factory)
        (flag[:prerequisites] || []).each do |prerequisite|
          prereq_ok = true
          prereq_key = prerequisite[:key]
          prereq_flag = @get_flag.call(prereq_key)

          if prereq_flag.nil?
            @logger.error { "[LDClient] Could not retrieve prerequisite flag \"#{prereq_key}\" when evaluating \"#{flag[:key]}\"" }
            prereq_ok = false
          else
            begin
              prereq_res = eval_internal(prereq_flag, user, events, event_factory)
              # Note that if the prerequisite flag is off, we don't consider it a match no matter what its
              # off variation was. But we still need to evaluate it in order to generate an event.
              if !prereq_flag[:on] || prereq_res.variation_index != prerequisite[:variation]
                prereq_ok = false
              end
              event = event_factory.new_eval_event(prereq_flag, user, prereq_res, nil, flag)
              events.push(event)
            rescue => exn
              Util.log_exception(@logger, "Error evaluating prerequisite flag \"#{prereq_key}\" for flag \"#{flag[:key]}\"", exn)
              prereq_ok = false
            end
          end
          if !prereq_ok
            reason = prerequisite[:_reason]  # try to use cached reason
            return reason.nil? ? EvaluationReason::prerequisite_failed(prereq_key) : reason
          end
        end
        nil
      end

      def rule_match_user(rule, user)
        return false if !rule[:clauses]

        (rule[:clauses] || []).each do |clause|
          return false if !clause_match_user(clause, user)
        end

        return true
      end

      def clause_match_user(clause, user)
        # In the case of a segment match operator, we check if the user is in any of the segments,
        # and possibly negate
        if clause[:op].to_sym == :segmentMatch
          result = (clause[:values] || []).any? { |v|
            segment = @get_segment.call(v)
            !segment.nil? && segment_match_user(segment, user)
          }
          clause[:negate] ? !result : result
        else
          clause_match_user_no_segments(clause, user)
        end
      end

      def clause_match_user_no_segments(clause, user)
        user_val = EvaluatorOperators.user_value(user, clause[:attribute])
        return false if user_val.nil?

        op = clause[:op].to_sym
        clause_vals = clause[:values]
        result = if user_val.is_a? Enumerable
          user_val.any? { |uv| clause_vals.any? { |cv| EvaluatorOperators.apply(op, uv, cv) } }
        else
          clause_vals.any? { |cv| EvaluatorOperators.apply(op, user_val, cv) }
        end
        clause[:negate] ? !result : result
      end

      def segment_match_user(segment, user)
        return false unless user[:key]

        return true if segment[:included].include?(user[:key])
        return false if segment[:excluded].include?(user[:key])

        (segment[:rules] || []).each do |r|
          return true if segment_rule_match_user(r, user, segment[:key], segment[:salt])
        end

        return false
      end

      def segment_rule_match_user(rule, user, segment_key, salt)
        (rule[:clauses] || []).each do |c|
          return false unless clause_match_user_no_segments(c, user)
        end

        # If the weight is absent, this rule matches
        return true if !rule[:weight]
        
        # All of the clauses are met. See if the user buckets in
        bucket = EvaluatorBucketing.bucket_user(user, segment_key, rule[:bucketBy].nil? ? "key" : rule[:bucketBy], salt)
        weight = rule[:weight].to_f / 100000.0
        return bucket < weight
      end

      private

      def get_variation(flag, index, reason)
        if index < 0 || index >= flag[:variations].length
          @logger.error("[LDClient] Data inconsistency in feature flag \"#{flag[:key]}\": invalid variation index")
          return Evaluator.error_result(EvaluationReason::ERROR_MALFORMED_FLAG)
        end
        EvaluationDetail.new(flag[:variations][index], index, reason)
      end

      def get_off_value(flag, reason)
        if flag[:offVariation].nil?  # off variation unspecified - return default value
          return EvaluationDetail.new(nil, nil, reason)
        end
        get_variation(flag, flag[:offVariation], reason)
      end

      def get_value_for_variation_or_rollout(flag, vr, user, reason)
        index = EvaluatorBucketing.variation_index_for_user(flag, vr, user)
        if index.nil?
          @logger.error("[LDClient] Data inconsistency in feature flag \"#{flag[:key]}\": variation/rollout object with no variation or rollout")
          return Evaluator.error_result(EvaluationReason::ERROR_MALFORMED_FLAG)
        end
        return get_variation(flag, index, reason)
      end
    end
  end
end
