require "erb"

module LaunchDarkly
  module Impl
    module Context
      ERR_KIND_NON_STRING = 'context kind must be a string'
      ERR_KIND_CANNOT_BE_KIND = '"kind" is not a valid context kind'
      ERR_KIND_CANNOT_BE_MULTI = '"multi" is not a valid context kind'
      ERR_KIND_INVALID_CHARS = 'context kind contains disallowed characters'

      ERR_KEY_NON_STRING = 'context key must be a string'
      ERR_KEY_EMPTY = 'context key must not be empty'

      ERR_NAME_NON_STRING = 'context name must be a string'

      ERR_ANONYMOUS_NON_BOOLEAN = 'context anonymous must be a boolean'

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
      # Returns an error message if the kind is invalid; nil otherwise.
      #
      # @param kind [any]
      # @return [String, nil]
      #
      def self.validate_kind(kind)
        return ERR_KIND_NON_STRING unless kind.is_a?(String)
        return ERR_KIND_CANNOT_BE_KIND if kind == "kind"
        return ERR_KIND_CANNOT_BE_MULTI if kind == "multi"
        return ERR_KIND_INVALID_CHARS unless kind.match?(/^[\w.-]+$/)
      end

      #
      # Returns an error message if the key is invalid; nil otherwise.
      #
      # @param key [any]
      # @return [String, nil]
      #
      def self.validate_key(key)
        return ERR_KEY_NON_STRING unless key.is_a?(String)
        return ERR_KEY_EMPTY if key == ""
      end

      #
      # Returns an error message if the name is invalid; nil otherwise.
      #
      # @param name [any]
      # @return [String, nil]
      #
      def self.validate_name(name)
        return ERR_NAME_NON_STRING unless name.nil? || name.is_a?(String)
      end

      #
      # Returns an error message if anonymous is invalid; nil otherwise.
      #
      # @param anonymous [any]
      # @param allow_nil [Boolean]
      # @return [String, nil]
      #
      def self.validate_anonymous(anonymous, allow_nil)
        return nil if anonymous.nil? && allow_nil
        return nil if [true, false].include? anonymous

        ERR_ANONYMOUS_NON_BOOLEAN
      end

      #
      # @param kind [String]
      # @param key [String]
      # @return [String]
      #
      def self.canonicalize_key_for_kind(kind, key)
        # When building a FullyQualifiedKey, ':' and '%' are percent-escaped;
        # we do not use a full URL-encoding function because implementations of
        # this are inconsistent across platforms.
        encoded = key.gsub("%", "%25").gsub(":", "%3A")

        "#{kind}:#{encoded}"
      end
    end
  end
end
