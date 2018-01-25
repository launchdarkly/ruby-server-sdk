require "date"
require "semantic"

module LaunchDarkly
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
      if v.is_a? String
        for _ in 0..2 do
          begin
            return Semantic::Version.new(v)
          rescue ArgumentError
            v = addZeroVersionComponent(v)
          end
        end
      end
      nil
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

    class EvaluationError < StandardError
    end

    # Evaluates a feature flag, returning a hash containing the evaluation result and any events
    # generated during prerequisite evaluation. Raises EvaluationError if the flag is not well-formed
    # Will return nil, but not raise an exception, indicating that the rules (including fallthrough) did not match
    # In that case, the caller should return the default value.
    def evaluate(flag, user, feature_store)
      if flag.nil?
        raise EvaluationError, "Flag does not exist"
      end

      if user.nil? || user[:key].nil?
        raise EvaluationError, "Invalid user"
      end

      events = []

      if flag[:on]
        res = eval_internal(flag, user, feature_store, events)

        return { value: res, events: events } if !res.nil?
      end

      if !flag[:offVariation].nil? && flag[:offVariation] < flag[:variations].length
        value = flag[:variations][flag[:offVariation]]
        return { value: value, events: events }
      end

      { value: nil, events: events }
    end

    def eval_internal(flag, user, feature_store, events)
      failed_prereq = false
      # Evaluate prerequisites, if any
      if !flag[:prerequisites].nil?
        flag[:prerequisites].each do |prerequisite|
          prereq_flag = feature_store.get(prerequisite[:key])

          if prereq_flag.nil? || !prereq_flag[:on]
            failed_prereq = true
          else
            begin
              prereq_res = eval_internal(prereq_flag, user, feature_store, events)
              variation = get_variation(prereq_flag, prerequisite[:variation])
              events.push(kind: "feature", key: prereq_flag[:key], value: prereq_res, version: prereq_flag[:version], prereqOf: flag[:key])
              if prereq_res.nil? || prereq_res != variation
                failed_prereq = true
              end
            rescue => exn
              @config.logger.error("[LDClient] Error evaluating prerequisite: #{exn.inspect}")
              failed_prereq = true
            end
          end
        end

        if failed_prereq
          return nil
        end
      end
      # The prerequisites were satisfied.
      # Now walk through the evaluation steps and get the correct
      # variation index
      eval_rules(flag, user, feature_store)
    end

    def eval_rules(flag, user, feature_store)
      # Check user target matches
      if !flag[:targets].nil?
        flag[:targets].each do |target|
          if !target[:values].nil?
            target[:values].each do |value|
              return get_variation(flag, target[:variation]) if value == user[:key]
            end
          end
        end
      end

      # Check custom rules
      if !flag[:rules].nil?
        flag[:rules].each do |rule|
          return variation_for_user(rule, user, flag) if rule_match_user(rule, user, feature_store)
        end
      end

      # Check the fallthrough rule
      if !flag[:fallthrough].nil?
        return variation_for_user(flag[:fallthrough], user, flag)
      end

      # Not even the fallthrough matched-- return the off variation or default
      nil
    end

    def get_variation(flag, index)
      if index >= flag[:variations].length
        raise EvaluationError, "Invalid variation index"
      end
      flag[:variations][index]
    end

    def rule_match_user(rule, user, feature_store)
      return false if !rule[:clauses]

      rule[:clauses].each do |clause|
        return false if !clause_match_user(clause, user, feature_store)
      end

      return true
    end

    def clause_match_user(clause, user, feature_store)
      # In the case of a segment match operator, we check if the user is in any of the segments,
      # and possibly negate
      if (clause[:op] == :segmentMatch)
        clause[:values].each do |v|
          segment = feature_store.get(SEGMENTS, v)
          if !segment.nil?
            return maybe_negate(clause, true) if segment_match_user(segment, user)
          end
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
        raise EvaluationError, "Unsupported operator #{clause[:op]} in evaluation"
      end

      if val.is_a? Enumerable
        val.each do |v|
          return maybe_negate(clause, true) if match_any(op, v, clause[:values])
        end
        return maybe_negate(clause, false)
      end

      maybe_negate(clause, match_any(op, val, clause[:values]))
    end

    def variation_for_user(rule, user, flag)
      if !rule[:variation].nil? # fixed variation
        return get_variation(flag, rule[:variation])
      elsif !rule[:rollout].nil? # percentage rollout
        rollout = rule[:rollout]
        bucket_by = rollout[:bucketBy].nil? ? "key" : rollout[:bucketBy]
        bucket = bucket_user(user, flag[:key], bucket_by, flag[:salt])
        sum = 0;
        rollout[:variations].each do |variate|
          sum += variate[:weight].to_f / 100000.0
          return get_variation(flag, variate[:variation]) if bucket < sum
        end
        nil
      else # the rule isn't well-formed
        raise EvaluationError, "Rule does not define a variation or rollout"
      end
    end

    def segment_match_user(segment, user)
      return false unless user[:key]

      return true if segment[:included].include?(user[:key])
      return false if segment[:excluded].include?(user[:key])

      segment[:rules].each do |r|
        return true if segment_rule_match_user(r, user, segment[:key], segment[:salt])
      end

      return false
    end

    def segment_rule_match_user(rule, user, segment_key, salt)
      rule[:clauses].each do |c|
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

      id_hash = user_value(user, bucket_by)

      if user[:secondary]
        id_hash += "." + user[:secondary]
      end

      hash_key = "%s.%s.%s" % [key, salt, id_hash]

      hash_val = (Digest::SHA1.hexdigest(hash_key))[0..14]
      hash_val.to_i(16) / Float(0xFFFFFFFFFFFFFFF)
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
  end
end
