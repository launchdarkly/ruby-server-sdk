require 'set'
require 'ldclient-rb/impl/context'

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
    # @return [String] Returns the key for this context
    attr_reader :key

    # @return [String] Returns the kind for this context
    attr_reader :kind

    # @return [String, nil] Returns the error associated with this LDContext if invalid
    attr_reader :error

    #
    # @private
    # @param key [String]
    # @param kind [String]
    # @param secondary [String, nil]
    # @param attributes [Hash, nil]
    # @param private_attributes [Array<String>, nil]
    # @param error [String, nil]
    # @param contexts [Array<LDContext>, nil]
    #
    def initialize(key, kind, secondary = nil, attributes = nil, private_attributes = nil, error = nil, contexts = nil)
      @key = key
      @kind = kind
      @secondary = secondary
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

    # TODO: Update this method to support references.
    #
    # This method will be changing in subsequent PRs. Eventually it will
    # receive a Reference or a string that we will turn into a Reference and
    # then we will use that new reference to retrieve the correct value.
    #
    # However, I want to break this up into multiple PRs. So for now, this is
    # doing some very basic lookups so I can verify the little bit of behavior
    # I have so far.
    #
    # Later work will update this code and the tests.
    #
    # @param attribute [Symbol]
    #
    def get_value(attribute)
      return nil unless valid?

      case attribute
      when :key
        @key
      when :kind
        @kind
      when :secondary
        @secondary
      else
        @attributes[attribute]
      end
    end

    #
    # Convenience method to create a simple single kind context providing only
    # a key and kind type.
    #
    # @param key [String]
    # @param kind [String]
    #
    def self.with_key(key, kind = "user")
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
      return create_context_from_legacy_data(data) unless data.has_key?(:kind)

      kind = data[:kind]
      unless LaunchDarkly::Impl::Context.validate_kind(kind)
        create_invalid_context("The kind (#{kind || 'nil'}) was not valid for the provided context.")
      end

      key = data[:key]
      unless LaunchDarkly::Impl::Context.validate_key(key)
        return create_invalid_context("The key (#{key || 'nil'}) was not valid for the provided context.")
      end

      meta = data.fetch(:_meta, {})
      private_attributes = meta[:privateAttributes]
      if private_attributes && !private_attributes.is_a?(Array)
        return create_invalid_context("The provided private attributes are not an array")
      end

      attributes = {}
      data.each do |k, v|
        # :secondary is not a supported top level key in the new schema.
        # However, someone could still include it so we need to ignore it.
        attributes[k] = v.clone unless [:key, :kind, :_meta, :secondary].include? k
      end

      new(key, kind, meta[:secondary], attributes, private_attributes)
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
    # @param contexts [Array<String>]
    # @return LDContext
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

      new(nil, "multi", nil, nil, nil, nil, contexts)
    end

    #
    # @param error [String]
    # @return LDContext
    #
    private_class_method def self.create_invalid_context(error)
      return new(nil, nil, nil, nil, nil, "Cannot create an LDContext. Provided data is not a hash.")
    end

    #
    # @param data [Hash]
    # @return LDContext
    #
    private_class_method def self.create_context_from_legacy_data(data)
      key = data[:key]

      # Legacy users are allowed to have "" as a key but they cannot have nil as a key.
      return create_invalid_context("The key for the context was not valid") if key.nil?

      attributes = data[:custom].clone || {}
      built_in_attributes = [:key, :ip, :email, :name, :avatar, :firstName, :lastName, :country, :anonymous]
      built_in_attributes.each do |attr|
        attributes[attr] = data[attr].clone if data.has_key? attr
      end

      private_attributes = data[:privateAttributeNames]
      if private_attributes && !private_attributes.is_a?(Array)
        return create_invalid_context("The provided private attributes are not an array")
      end

      return new(key, "user", data[:secondary], attributes, private_attributes)
    end
  end
end
