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
        ERR_KIND_INVALID_CHARS unless kind.match?(/^[\w.-]+$/)
      end

      #
      # Returns an error message if the key is invalid; nil otherwise.
      #
      # @param key [any]
      # @return [String, nil]
      #
      def self.validate_key(key)
        return ERR_KEY_NON_STRING unless key.is_a?(String)
        ERR_KEY_EMPTY if key == ""
      end

      #
      # Returns an error message if the name is invalid; nil otherwise.
      #
      # @param name [any]
      # @return [String, nil]
      #
      def self.validate_name(name)
        ERR_NAME_NON_STRING unless name.nil? || name.is_a?(String)
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
      # Attribute reference components are always symbols, but application data
      # can use string keys. For example, JSON.parse makes string keys by
      # default. The two forms name the same JSON property, so this method
      # compares them as equal.
      #
      # @param component [Symbol]
      # @param key [any]
      # @return [Boolean]
      #
      def self.same_attribute_name?(component, key)
        component == key || component.to_s == key.to_s
      end

      #
      # Read an attribute out of a hash by name. The hash can use symbol or
      # string keys, and the name can be either form. An exact match wins, then
      # the other form. A symbol therefore takes precedence when the hash holds
      # both forms of one name.
      #
      # The first element of the returned array is true if the hash has the
      # attribute. The second element is the value, or nil if there is none.
      #
      # @param hash [Hash]
      # @param name [Symbol, String]
      # @return [Array(Boolean, any)]
      #
      def self.fetch_attribute(hash, name)
        return true, hash[name] if hash.has_key?(name)

        alternate = name.is_a?(Symbol) ? name.to_s : name.to_sym
        return true, hash[alternate] if hash.has_key?(alternate)

        [false, nil]
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
