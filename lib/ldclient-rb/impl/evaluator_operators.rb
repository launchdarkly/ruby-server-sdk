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
      # @param user_value the value of the user attribute that is referenced in the current clause (left-hand
      #   side of the expression)
      # @param clause_value the constant value that `user_value` is being compared to (right-hand side of the
      #   expression)
      # @return [Boolean] true if the expression should be considered a match; false if it is not a match, or
      #   if the values cannot be compared because they are of the wrong types, or if the operator is unknown
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
          # We should never reach this; it can't be evaluated based on just two parameters, because it requires
          # looking up the segment from the data store. Instead, we special-case this operator in clause_match_user.
          false
        else
          false
        end
      end

      # Retrieves the value of a user attribute by name.
      #
      # Built-in attributes correspond to top-level properties in the user object. They are treated as strings and
      # non-string values are coerced to strings, except for `anonymous` which is treated as a boolean if present
      # (using Ruby's "truthiness" standard). The coercion behavior is not guaranteed to be consistent with other
      # SDKs; the built-in attributes should not be set to values of the wrong type (in the strongly-typed SDKs,
      # they can't be, and in a future version of the Ruby SDK we may make it impossible to do so).
      #
      # Custom attributes correspond to properties within the `custom` property, if any, and can be of any type.
      #
      # @param user [Object] the user properties
      # @param attribute [String|Symbol] the attribute to get, for instance `:key` or `:name` or `:some_custom_attr`
      # @return the attribute value, or nil if the attribute is unknown
      def self.user_value(user, attribute)
        attribute = attribute.to_sym
        if BUILTINS.include? attribute
          value = user[attribute]
          return nil if value.nil?
          (attribute == :anonymous) ? !!value : value.to_s
        elsif !user[:custom].nil?
          user[:custom][attribute]
        else
          nil
        end
      end

      private

      BUILTINS = Set[:key, :ip, :country, :email, :firstName, :lastName, :avatar, :name, :anonymous]
      NON_STRING_BUILTINS = Set[:anonymous]
      NUMERIC_VERSION_COMPONENTS_REGEX = Regexp.new("^[0-9.]*")

      private_constant :BUILTINS
      private_constant :NON_STRING_BUILTINS
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
