require "date"
require "semantic"

module LaunchDarkly
  module Impl
    module EvaluatorOperators
      def self.apply(op, user_value, clause_value)
        case op
        when :in
          user_value == clause_value
        when :startsWith
          string_op(user_value, clause_value, lambda { |a, b| a.start_with? b })
        when :endsWith
          string_op(user_value, clause_value, lambda { |a, b| a.end_with? b })
        when :contains
          string_op(user_value, clause_value, lambda { |a, b| a.include? b })
        when :matches
          string_op(user_value, clause_value, lambda { |a, b| !(Regexp.new b).match(a).nil? })
        when :lessThan
          numeric_op(user_value, clause_value, lambda { |a, b| a < b })
        when :lessThanOrEqual
          numeric_op(user_value, clause_value, lambda { |a, b| a <= b })
        when :greaterThan
          numeric_op(user_value, clause_value, lambda { |a, b| a > b })
        when :greaterThanOrEqual
          numeric_op(user_value, clause_value, lambda { |a, b| a >= b })
        when :before
          date_op(user_value, clause_value, lambda { |a, b| a < b })
        when :after
          date_op(user_value, clause_value, lambda { |a, b| a > b })
        when :semVerEqual
          semver_op(user_value, clause_value, lambda { |a, b| a == b })
        when :semVerLessThan
          semver_op(user_value, clause_value, lambda { |a, b| a < b })
        when :semVerGreaterThan
          semver_op(user_value, clause_value, lambda { |a, b| a > b })
        when :segmentMatch
          false   # we should never reach this - instead we special-case this operator in clause_match_user
        else
          false
        end
      end

      def self.user_value(user, attribute)
        attribute = attribute.to_sym
        if BUILTINS.include? attribute
          value = user[attribute]
          return value.to_s if !value.nil? && !(value.is_a? String)
          value
        elsif !user[:custom].nil?
          user[:custom][attribute]
        else
          nil
        end
      end

      private

      BUILTINS = [:key, :ip, :country, :email, :firstName, :lastName, :avatar, :name, :anonymous]
      NUMERIC_VERSION_COMPONENTS_REGEX = Regexp.new("^[0-9.]*")

      private_constant :BUILTINS
      private_constant :NUMERIC_VERSION_COMPONENTS_REGEX

      def self.string_op(user_value, clause_value, fn)
        (user_value.is_a? String) && (clause_value.is_a? String) && fn.call(user_value, clause_value)
      end

      def self.numeric_op(user_value, clause_value, fn)
        (user_value.is_a? Numeric) && (clause_value.is_a? Numeric) && fn.call(user_value, clause_value)
      end

      def self.date_op(user_value, clause_value, fn)
        ud = to_date(user_value)
        if !ud.nil?
          cd = to_date(clause_value)
          !cd.nil? && fn.call(ud, cd)
        else
          false
        end
      end

      def self.semver_op(user_value, clause_value, fn)
        uv = to_semver(user_value)
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
