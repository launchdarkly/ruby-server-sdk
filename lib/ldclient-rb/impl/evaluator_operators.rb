require "date"
require "semantic"
require "set"

module LaunchDarkly
  module Impl
    # Defines the behavior of all operators that can be used in feature flag rules and segment rules.
    module EvaluatorOperators
      # Applies an operator to produce a boolean result.
      #
      # @param op [Symbol] one of the supported LaunchDarkly operators, as a symbol
      # @param context_value the value of the context attribute that is referenced in the current clause (left-hand
      #   side of the expression)
      # @param clause_value the constant value that `context_value` is being compared to (right-hand side of the
      #   expression)
      # @return [Boolean] true if the expression should be considered a match; false if it is not a match, or
      #   if the values cannot be compared because they are of the wrong types, or if the operator is unknown
      def self.apply(op, context_value, clause_value)
        case op
        when :in
          context_value == clause_value
        when :startsWith
          string_op(context_value, clause_value, lambda { |a, b| a.start_with? b })
        when :endsWith
          string_op(context_value, clause_value, lambda { |a, b| a.end_with? b })
        when :contains
          string_op(context_value, clause_value, lambda { |a, b| a.include? b })
        when :matches
          string_op(context_value, clause_value, lambda { |a, b|
            begin
              re = Regexp.new b
              !re.match(a).nil?
            rescue
              false
            end
          })
        when :lessThan
          numeric_op(context_value, clause_value, lambda { |a, b| a < b })
        when :lessThanOrEqual
          numeric_op(context_value, clause_value, lambda { |a, b| a <= b })
        when :greaterThan
          numeric_op(context_value, clause_value, lambda { |a, b| a > b })
        when :greaterThanOrEqual
          numeric_op(context_value, clause_value, lambda { |a, b| a >= b })
        when :before
          date_op(context_value, clause_value, lambda { |a, b| a < b })
        when :after
          date_op(context_value, clause_value, lambda { |a, b| a > b })
        when :semVerEqual
          semver_op(context_value, clause_value, lambda { |a, b| a == b })
        when :semVerLessThan
          semver_op(context_value, clause_value, lambda { |a, b| a < b })
        when :semVerGreaterThan
          semver_op(context_value, clause_value, lambda { |a, b| a > b })
        when :segmentMatch
          # We should never reach this; it can't be evaluated based on just two parameters, because it requires
          # looking up the segment from the data store. Instead, we special-case this operator in clause_match_context.
          false
        else
          false
        end
      end

      private

      NUMERIC_VERSION_COMPONENTS_REGEX = Regexp.new("^[0-9.]*")
      private_constant :NUMERIC_VERSION_COMPONENTS_REGEX

      def self.string_op(context_value, clause_value, fn)
        (context_value.is_a? String) && (clause_value.is_a? String) && fn.call(context_value, clause_value)
      end

      def self.numeric_op(context_value, clause_value, fn)
        (context_value.is_a? Numeric) && (clause_value.is_a? Numeric) && fn.call(context_value, clause_value)
      end

      def self.date_op(context_value, clause_value, fn)
        ud = to_date(context_value)
        if !ud.nil?
          cd = to_date(clause_value)
          !cd.nil? && fn.call(ud, cd)
        else
          false
        end
      end

      def self.semver_op(context_value, clause_value, fn)
        uv = to_semver(context_value)
        if !uv.nil?
          cv = to_semver(clause_value)
          !cv.nil? && fn.call(uv, cv)
        else
          false
        end
      end

      def self.to_date(value)
        if value.is_a? String
          begin
            DateTime.rfc3339(value).strftime("%Q").to_i
          rescue => e
            nil
          end
        elsif value.is_a? Numeric
          value
        else
          nil
        end
      end

      def self.to_semver(value)
        if value.is_a? String
          for _ in 0..2 do
            begin
              return Semantic::Version.new(value)
            rescue ArgumentError
              value = add_zero_version_component(value)
            end
          end
        end
        nil
      end

      def self.add_zero_version_component(v)
        NUMERIC_VERSION_COMPONENTS_REGEX.match(v) { |m|
          m[0] + ".0" + v[m[0].length..-1]
        }
      end
    end
  end
end
