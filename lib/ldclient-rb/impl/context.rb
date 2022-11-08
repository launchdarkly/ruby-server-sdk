module LaunchDarkly
  module Impl
    module Context
      #
      # We allow consumers of this SDK to provide us with either a Hash or an
      # instance of an LDContext. This is convenient for them but not as much
      # for us. To make the conversion slightly more convenient for us, we have
      # created this method.
      #
      # @param context [Hash, LDContext]
      # @return [LDContext]
      #
      def self.make_context(context)
        return context if context.is_a?(LDContext)

        LDContext.create(context)
      end

      #
      # @param kind [any]
      # @return [Boolean]
      #
      def self.validate_kind(kind)
        return false unless kind.is_a?(String)
        kind.match?(/^[\w.-]+$/) && kind != "kind" && kind != "multi"
      end

      #
      # @param key [any]
      # @return [Boolean]
      #
      def self.validate_key(key)
        return false unless key.is_a?(String)
        key != ""
      end

      #
      # @param name [any]
      # @return [Boolean]
      #
      def self.validate_name(name)
        name.nil? || name.is_a?(String)
      end

      #
      # @param anonymous [any]
      # @param allow_nil [Boolean]
      # @return [Boolean]
      #
      def self.validate_anonymous(anonymous, allow_nil)
        return true if anonymous.nil? && allow_nil
        [true, false].include? anonymous
      end
    end
  end
end
