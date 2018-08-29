require "date"
require "semantic"

module LaunchDarkly
  # An object returned by `LDClient.variation_detail`, combining the result of a flag evaluation with
  # an explanation of how it was calculated.
  class EvaluationDetail
    def initialize(value, variation_index, reason)
      @value = value
      @variation_index = variation_index
      @reason = reason
    end

    # @return [Object] The result of the flag evaluation. This will be either one of the flag's
    #   variations or the default value that was passed to the `variation` method.
    attr_reader :value

    # @return [int|nil] The index of the returned value within the flag's list of variations, e.g.
    #   0 for the first variation - or `nil` if the default value was returned.
    attr_reader :variation_index

    # @return [Hash] An object describing the main factor that influenced the flag evaluation value.
    attr_reader :reason

    # @return [boolean] True if the flag evaluated to the default value rather than to one of its
    #   variations.
    def default_value?
      variation_index.nil?
    end

    def ==(other)
      @value == other.value && @variation_index == other.variation_index && @reason == other.reason
    end
  end

  module Evaluation
    BUILTINS = [:key, :ip, :country, :email, :firstName, :lastName, :avatar, :name, :anonymous]

    NUMERIC_VERSION_COMPONENTS_REGEX = Regexp.new("^[0-9.]*")

    DATE_OPERAND = lambda do |v|
      if v.is_a? String
        begin
          DateTime.rfc3339(v).strftime("%Q").to_i
        rescue => e
          nil
        end
      elsif v.is_a? Numeric
        v
      else
        nil
      end
    end

    SEMVER_OPERAND = lambda do |v|
      semver = nil
      if v.is_a? String
        for _ in 0..2 do
          begin
            semver = Semantic::Version.new(v)
            break  # Some versions of jruby cannot properly handle a return here and return from the method that calls this lambda
          rescue ArgumentError
            v = addZeroVersionComponent(v)
          end
        end
      end
      semver
    end

    def self.addZeroVersionComponent(v)
      NUMERIC_VERSION_COMPONENTS_REGEX.match(v) { |m|
        m[0] + ".0" + v[m[0].length..-1]
      }
    end

    def self.comparator(converter)
      lambda do |a, b|
        av = converter.call(a)
        bv = converter.call(b)
        if !av.nil? && !bv.nil?
          yield av <=> bv
        else
          return false
        end
      end
    end

    OPERATORS = {
      in:
        lambda do |a, b|
          a == b
        end,
      endsWith:
        lambda do |a, b|
          (a.is_a? String) && (a.end_with? b)
        end,
      startsWith:
        lambda do |a, b|
          (a.is_a? String) && (a.start_with? b)
        end,
      matches:
        lambda do |a, b|
          (b.is_a? String) && !(Regexp.new b).match(a).nil?
        end,
      contains:
        lambda do |a, b|
          (a.is_a? String) && (a.include? b)
        end,
      lessThan:
        lambda do |a, b|
          (a.is_a? Numeric) && (a < b)
        end,
      lessThanOrEqual:
        lambda do |a, b|
          (a.is_a? Numeric) && (a <= b)
        end,
      greaterThan:
        lambda do |a, b|
          (a.is_a? Numeric) && (a > b)
        end,
      greaterThanOrEqual:
        lambda do |a, b|
          (a.is_a? Numeric) && (a >= b)
        end,
      before:
        comparator(DATE_OPERAND) { |n| n < 0 },
      after:
        comparator(DATE_OPERAND) { |n| n > 0 },
      semVerEqual:
        comparator(SEMVER_OPERAND) { |n| n == 0 },
      semVerLessThan:
        comparator(SEMVER_OPERAND) { |n| n < 0 },
      semVerGreaterThan:
        comparator(SEMVER_OPERAND) { |n| n > 0 },
      segmentMatch:
        lambda do |a, b|
          false   # we should never reach this - instead we special-case this operator in clause_match_user
        end
    }

    # Used internally to hold an evaluation result and the events that were generated from prerequisites.
    EvalResult = Struct.new(:detail, :events)

    def error_result(errorKind, value = nil)
      EvaluationDetail.new(value, nil, { kind: 'ERROR', errorKind: errorKind })
    end

    # Evaluates a feature flag and returns an EvalResult. The result.value will be nil if the flag returns
    # the default value. Error conditions produce a result with an error reason, not an exception.
    def evaluate(flag, user, store, logger)
      if user.nil? || user[:key].nil?
        return EvalResult.new(error_result('USER_NOT_SPECIFIED'), [])
      end

      events = []
      detail = eval_internal(flag, user, store, events, logger)
      return EvalResult.new(detail, events)
    end

    def eval_internal(flag, user, store, events, logger)
      if !flag[:on]
        return get_off_value(flag, { kind: 'OFF' }, logger)
      end

      prereq_failure_reason = check_prerequisites(flag, user, store, events, logger)
      if !prereq_failure_reason.nil?
        return get_off_value(flag, prereq_failure_reason, logger)
      end

      # Check user target matches
      (flag[:targets] || []).each do |target|
        (target[:values] || []).each do |value|
          if value == user[:key]
            return get_variation(flag, target[:variation], { kind: 'TARGET_MATCH' }, logger)
          end
        end
      end
    
      # Check custom rules
      rules = flag[:rules] || []
      rules.each_index do |i|
        rule = rules[i]
        if rule_match_user(rule, user, store)
          return get_value_for_variation_or_rollout(flag, rule, user,
            { kind: 'RULE_MATCH', ruleIndex: i, ruleId: rule[:id] }, logger)
        end
      end

      # Check the fallthrough rule
      if !flag[:fallthrough].nil?
        return get_value_for_variation_or_rollout(flag, flag[:fallthrough], user,
          { kind: 'FALLTHROUGH' }, logger)
      end

      return EvaluationDetail.new(nil, nil, { kind: 'FALLTHROUGH' })
    end

    def check_prerequisites(flag, user, store, events, logger)
      (flag[:prerequisites] || []).each do |prerequisite|
        prereq_ok = true
        prereq_key = prerequisite[:key]
        prereq_flag = store.get(FEATURES, prereq_key)

        if prereq_flag.nil?
          logger.error { "[LDClient] Could not retrieve prerequisite flag \"#{prereq_key}\" when evaluating \"#{flag[:key]}\"" }
          prereq_ok = false
        else
          begin
            prereq_res = eval_internal(prereq_flag, user, store, events, logger)
            # Note that if the prerequisite flag is off, we don't consider it a match no matter what its
            # off variation was. But we still need to evaluate it in order to generate an event.
            if !prereq_flag[:on] || prereq_res.variation_index != prerequisite[:variation]
              prereq_ok = false
            end
            event = {
              kind: "feature",
              key: prereq_key,
              variation: prereq_res.variation_index,
              value: prereq_res.value,
              version: prereq_flag[:version],
              prereqOf: flag[:key],
              trackEvents: prereq_flag[:trackEvents],
              debugEventsUntilDate: prereq_flag[:debugEventsUntilDate]
            }
            events.push(event)
          rescue => exn
            Util.log_exception(logger, "Error evaluating prerequisite flag \"#{prereq_key}\" for flag \"{flag[:key]}\"", exn)
            prereq_ok = false
          end
        end
        if !prereq_ok
          return { kind: 'PREREQUISITE_FAILED', prerequisiteKey: prereq_key }
        end
      end
      nil
    end

    def rule_match_user(rule, user, store)
      return false if !rule[:clauses]

      (rule[:clauses] || []).each do |clause|
        return false if !clause_match_user(clause, user, store)
      end

      return true
    end

    def clause_match_user(clause, user, store)
      # In the case of a segment match operator, we check if the user is in any of the segments,
      # and possibly negate
      if clause[:op].to_sym == :segmentMatch
        (clause[:values] || []).each do |v|
          segment = store.get(SEGMENTS, v)
          return maybe_negate(clause, true) if !segment.nil? && segment_match_user(segment, user)
        end
        return maybe_negate(clause, false)
      end
      clause_match_user_no_segments(clause, user)
    end

    def clause_match_user_no_segments(clause, user)
      val = user_value(user, clause[:attribute])
      return false if val.nil?

      op = OPERATORS[clause[:op].to_sym]
      if op.nil?
        return false
      end

      if val.is_a? Enumerable
        val.each do |v|
          return maybe_negate(clause, true) if match_any(op, v, clause[:values])
        end
        return maybe_negate(clause, false)
      end

      maybe_negate(clause, match_any(op, val, clause[:values]))
    end

    def variation_index_for_user(flag, rule, user)
      if !rule[:variation].nil? # fixed variation
        return rule[:variation]
      elsif !rule[:rollout].nil? # percentage rollout
        rollout = rule[:rollout]
        bucket_by = rollout[:bucketBy].nil? ? "key" : rollout[:bucketBy]
        bucket = bucket_user(user, flag[:key], bucket_by, flag[:salt])
        sum = 0;
        rollout[:variations].each do |variate|
          sum += variate[:weight].to_f / 100000.0
          if bucket < sum
            return variate[:variation]
          end
        end
        nil
      else # the rule isn't well-formed
        nil
      end
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
      bucket = bucket_user(user, segment_key, rule[:bucketBy].nil? ? "key" : rule[:bucketBy], salt)
      weight = rule[:weight].to_f / 100000.0
      return bucket < weight
    end

    def bucket_user(user, key, bucket_by, salt)
      return nil unless user[:key]

      id_hash = bucketable_string_value(user_value(user, bucket_by))
      if id_hash.nil?
        return 0.0
      end

      if user[:secondary]
        id_hash += "." + user[:secondary]
      end

      hash_key = "%s.%s.%s" % [key, salt, id_hash]

      hash_val = (Digest::SHA1.hexdigest(hash_key))[0..14]
      hash_val.to_i(16) / Float(0xFFFFFFFFFFFFFFF)
    end

    def bucketable_string_value(value)
      return value if value.is_a? String
      return value.to_s if value.is_a? Integer
      nil
    end

    def user_value(user, attribute)
      attribute = attribute.to_sym

      if BUILTINS.include? attribute
        user[attribute]
      elsif !user[:custom].nil?
        user[:custom][attribute]
      else
        nil
      end
    end

    def maybe_negate(clause, b)
      clause[:negate] ? !b : b
    end

    def match_any(op, value, values)
      values.each do |v|
        return true if op.call(value, v)
      end
      return false
    end

    private

    def get_variation(flag, index, reason, logger)
      if index < 0 || index >= flag[:variations].length
        logger.error("[LDClient] Data inconsistency in feature flag \"#{flag[:key]}\": invalid variation index")
        return error_result('MALFORMED_FLAG')
      end
      EvaluationDetail.new(flag[:variations][index], index, reason)
    end

    def get_off_value(flag, reason, logger)
      if flag[:offVariation].nil?  # off variation unspecified - return default value
        return EvaluationDetail.new(nil, nil, reason)
      end
      get_variation(flag, flag[:offVariation], reason, logger)
    end

    def get_value_for_variation_or_rollout(flag, vr, user, reason, logger)
      index = variation_index_for_user(flag, vr, user)
      if index.nil?
        logger.error("[LDClient] Data inconsistency in feature flag \"#{flag[:key]}\": variation/rollout object with no variation or rollout")
        return error_result('MALFORMED_FLAG')
      end
      return get_variation(flag, index, reason, logger)
    end
  end
end
