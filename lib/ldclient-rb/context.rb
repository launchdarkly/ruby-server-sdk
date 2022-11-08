require 'set'
require 'ldclient-rb/impl/context'
require 'ldclient-rb/reference'

module LaunchDarkly
  # LDContext is a collection of attributes that can be referenced in flag
  # evaluations and analytics events.
  #
  # (TKTK - some conceptual text here, and/or a link to a docs page)
  #
  # To create an LDContext of a single kind, such as a user, you may use
  # {LDContext#create} or {LDContext#with_key}.
  #
  # To create an LDContext with multiple kinds, use {LDContext#create_multi}.
  #
  # Each factory method will always return an LDContext. However, that
  # LDContext may be invalid. You can check the validity of the resulting
  # context, and the associated errors by calling {LDContext#valid?} and
  # {LDContext#error}
  class LDContext
    KIND_DEFAULT = "user"
    KIND_MULTI = "multi"

    # @return [String, nil] Returns the key for this context
    attr_reader :key

    # @return [String, nil] Returns the kind for this context
    attr_reader :kind

    # @return [String, nil] Returns the error associated with this LDContext if invalid
    attr_reader :error

    #
    # @private
    # @param key [String, nil]
    # @param kind [String, nil]
    # @param name [String, nil]
    # @param anonymous [Boolean, nil]
    # @param attributes [Hash, nil]
    # @param private_attributes [Array<String>, nil]
    # @param error [String, nil]
    # @param contexts [Array<LDContext>, nil]
    #
    def initialize(key, kind, name = nil, anonymous = nil, attributes = nil, private_attributes = nil, error = nil, contexts = nil)
      @key = key
      @kind = kind
      @name = name
      @anonymous = anonymous || false
      @attributes = attributes
      @private_attributes = private_attributes
      @error = error
      @contexts = contexts
      @is_multi = !contexts.nil?
    end
    private_class_method :new

    #
    # @return [Boolean] Is this LDContext a multi-kind context?
    #
    def multi_kind?
      @is_multi
    end

    #
    # @return [Boolean] Determine if this LDContext is considered valid
    #
    def valid?
      @error.nil?
    end

    #
    # get_value looks up the value of any attribute of the Context by name.
    # This includes only attributes that are addressable in evaluations-- not
    # metadata such as private attributes.
    #
    # For a single-kind context, the attribute name can be any custom attribute.
    # It can also be one of the built-in ones like "kind", "key", or "name".
    #
    # For a multi-kind context, the only supported attribute name is "kind".
    # Use {#individual_context} to inspect a Context for a particular kind and
    # then get its attributes.
    #
    # This method does not support complex expressions for getting individual
    # values out of JSON objects or arrays, such as "/address/street". Use
    # {#get_value_for_reference} for that purpose.
    #
    # If the value is found, the return value is the attribute value;
    # otherwise, it is nil.
    #
    # @param attribute [String, Symbol]
    # @return [any]
    #
    def get_value(attribute)
      reference = Reference.create_literal(attribute)
      get_value_for_reference(reference)
    end

    #
    # get_value_for_reference looks up the value of any attribute of the
    # Context, or a value contained within an attribute, based on a {Reference}
    # instance. This includes only attributes that are addressable in
    # evaluations-- not metadata such as private attributes.
    #
    # This implements the same behavior that the SDK uses to resolve attribute
    # references during a flag evaluation. In a single-kind context, the
    # {Reference} can represent a simple attribute name-- either a built-in one
    # like "name" or "key", or a custom attribute -- or, it can be a
    # slash-delimited path using a JSON-Pointer-like syntax. See {Reference}
    # for more details.
    #
    # For a multi-kind context, the only supported attribute name is "kind".
    # Use {#individual_context} to inspect a Context for a particular kind and
    # then get its attributes.
    #
    # If the value is found, the return value is the attribute value;
    # otherwise, it is nil.
    #
    # @param reference [Reference]
    # @return [any]
    #
    def get_value_for_reference(reference)
      return nil unless valid?
      return nil unless reference.is_a?(Reference)
      return nil unless reference.error.nil?

      first_component = reference.component(0)
      return nil if first_component.nil?

      if multi_kind?
        if reference.depth == 1 && first_component == :kind
          return kind
        end

        # Multi-kind contexts have no other addressable attributes
        return nil
      end

      value = get_top_level_addressable_attribute_single_kind(first_component)
      return nil if value.nil?

      (1...reference.depth).each do |i|
        name = reference.component(i)

        return nil unless value.is_a?(Hash)
        return nil unless value.has_key?(name)

        value = value[name]
      end

      value
    end

    #
    # Returns the number of context kinds in this context.
    #
    # For a valid individual context, this returns 1. For a multi-context, it
    # returns the number of context kinds. For an invalid context, it returns
    # zero.
    #
    # @return [Integer] the number of context kinds
    #
    def individual_context_count
      return 0 unless valid?
      return 1 if @contexts.nil?
      @contexts.count
    end

    #
    # Returns the single-kind LDContext corresponding to one of the kinds in
    # this context.
    #
    # The `kind` parameter can be either a number representing a zero-based
    # index, or a string representing a context kind.
    #
    # If this method is called on a single-kind LDContext, then the only
    # allowable value for `kind` is either zero or the same value as {#kind},
    # and the return value on success is the same LDContext.
    #
    # If the method is called on a multi-context, and `kind` is a number, it
    # must be a non-negative index that is less than the number of kinds (that
    # is, less than the return value of {#individual_context_count}, and the
    # return value on success is one of the individual LDContexts within. Or,
    # if `kind` is a string, it must match the context kind of one of the
    # individual contexts.
    #
    # If there is no context corresponding to `kind`, the method returns nil.
    #
    # @param kind [Integer, String] the index or string value of a context kind
    # @return [LDContext, nil] the context corresponding to that index or kind,
    #   or null if none.
    #
    def individual_context(kind)
      return nil unless valid?

      if kind.is_a?(Integer)
        unless multi_kind?
          return kind == 0 ? self : nil
        end

        return kind >= 0 && kind < @contexts.count ? @contexts[kind] : nil
      end

      return nil unless kind.is_a?(String)

      unless multi_kind?
        return self.kind == kind ? self : nil
      end

      @contexts.each do |context|
        return context if context.kind == kind
      end

      nil
    end

    #
    # Retrieve the value of any top level, addressable attribute.
    #
    # This method returns an array of two values. The first element is the
    # value of the requested attribute or nil if it does not exist. The second
    # value will be true if the attribute exists; otherwise, it will be false.
    #
    # @param name [Symbol]
    # @return [any]
    #
    private def get_top_level_addressable_attribute_single_kind(name)
      case name
      when :kind
        kind
      when :key
        key
      when :name
        @name
      when :anonymous
        @anonymous
      else
        @attributes&.fetch(name, nil)
      end
    end

    #
    # Convenience method to create a simple single kind context providing only
    # a key and kind type.
    #
    # @param key [String]
    # @param kind [String]
    #
    def self.with_key(key, kind = KIND_DEFAULT)
      create({key: key, kind: kind})
    end

    #
    # Create a single kind context from the provided hash.
    #
    # The provided hash must match the format as outlined in the
    # {https://docs.launchdarkly.com/sdk/features/user-config SDK
    # documentation}.
    #
    # TKTK: Update this link once we know what the new one will be.
    #
    # @param data [Hash]
    # @return [LDContext]
    #
    def self.create(data)
      return create_invalid_context("Cannot create an LDContext. Provided data is not a hash.") unless data.is_a?(Hash)
      return create_legacy_context(data) unless data.has_key?(:kind)

      kind = data[:kind]
      if kind == KIND_MULTI
        contexts = []
        data.each do |key, value|
          next if key == :kind
          contexts << create_single_context(value, key.to_s)
        end

        return create_multi(contexts)
      end

      create_single_context(data, kind)
    end

    #
    # Create a multi-kind context from the array of LDContexts provided.
    #
    # A multi-kind context is comprised of two or more single kind contexts.
    # You cannot include a multi-kind context instead another multi-kind
    # context.
    #
    # Additionally, the kind of each single-kind context must be unique. For
    # instance, you cannot create a multi-kind context that includes two user
    # kind contexts.
    #
    # If you attempt to create a multi-kind context from one single-kind
    # context, this method will return the single-kind context instead of a new
    # multi-kind context wrapping that one single-kind.
    #
    # @param contexts [Array<LDContext>]
    # @return [LDContext]
    #
    def self.create_multi(contexts)
      return create_invalid_context("Multi-kind context requires an array of LDContexts") unless contexts.is_a?(Array)
      return create_invalid_context("Multi-kind context requires at least one context") if contexts.empty?

      kinds = Set.new
      contexts.each do |context|
        if !context.is_a?(LDContext)
          return create_invalid_context("Provided context is not an instance of LDContext")
        elsif !context.valid?
          return create_invalid_context("Provided context #{context.key} is invalid")
        elsif context.multi_kind?
          return create_invalid_context("Provided context #{context.key} is a multi-kind context")
        elsif kinds.include? context.kind
          return create_invalid_context("Kind #{context.kind} cannot occur twice in the same multi-kind context")
        end

        kinds.add(context.kind)
      end

      return contexts[0] if contexts.length == 1

      new(nil, "multi", nil, false, nil, nil, nil, contexts)
    end

    #
    # @param error [String]
    # @return [LDContext]
    #
    private_class_method def self.create_invalid_context(error)
      new(nil, nil, nil, false, nil, nil, error)
    end

    #
    # @param data [Hash]
    # @return [LDContext]
    #
    private_class_method def self.create_legacy_context(data)
      key = data[:key]

      # Legacy users are allowed to have "" as a key but they cannot have nil as a key.
      return create_invalid_context("The key for the context was not valid") if key.nil?

      name = data[:name]
      unless LaunchDarkly::Impl::Context.validate_name(name)
        return create_invalid_context("The name value was set to a non-string value.")
      end

      anonymous = data[:anonymous]
      unless LaunchDarkly::Impl::Context.validate_anonymous(anonymous, true)
        return create_invalid_context("The anonymous value was set to a non-boolean value.")
      end

      custom = data[:custom]
      unless custom.nil? || custom.is_a?(Hash)
        return create_invalid_context("The custom value was set to a non-hash value.")
      end

      # We only need to create an attribute hash if one of these keys exist.
      # Everything else is stored in dedicated instance variables.
      attributes = custom.clone
      data.each do |k, v|
        case k
        when :ip, :email, :avatar, :firstName, :lastName, :country
          attributes ||= {}
          attributes[k] = v.clone
        else
          next
        end
      end

      private_attributes = data[:privateAttributeNames]
      if private_attributes && !private_attributes.is_a?(Array)
        return create_invalid_context("The provided private attributes are not an array")
      end

      new(key.to_s, KIND_DEFAULT, name, anonymous, attributes, private_attributes)
    end

    #
    # @param data [Hash]
    # @param kind [String]
    # @return [LaunchDarkly::LDContext]
    #
    private_class_method def self.create_single_context(data, kind)
      unless data.is_a?(Hash)
        return create_invalid_context("The provided data was not a hash")
      end

      unless LaunchDarkly::Impl::Context.validate_kind(kind)
        return create_invalid_context("The kind (#{kind || 'nil'}) was not valid for the provided context.")
      end

      key = data[:key]
      unless LaunchDarkly::Impl::Context.validate_key(key)
        return create_invalid_context("The key (#{key || 'nil'}) was not valid for the provided context.")
      end

      name = data[:name]
      unless LaunchDarkly::Impl::Context.validate_name(name)
        return create_invalid_context("The name value was set to a non-string value.")
      end

      anonymous = data.fetch(:anonymous, false)
      unless LaunchDarkly::Impl::Context.validate_anonymous(anonymous, false)
        return create_invalid_context("The anonymous value was set to a non-boolean value.")
      end

      meta = data.fetch(:_meta, {})
      private_attributes = meta[:privateAttributes]
      if private_attributes && !private_attributes.is_a?(Array)
        return create_invalid_context("The provided private attributes are not an array")
      end

      # We only need to create an attribute hash if there are keys set outside
      # of the ones we store in dedicated instance variables.
      attributes = nil
      data.each do |k, v|
        case k
        when :kind, :key, :name, :anonymous, :_meta
          next
        else
          attributes ||= {}
          attributes[k] = v.clone
        end
      end

      new(key.to_s, kind, name, anonymous, attributes, private_attributes)
    end
  end
end
