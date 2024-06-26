module LaunchDarkly
  #
  # Reference is an attribute name or path expression identifying a value
  # within a Context.
  #
  # This type is mainly intended to be used internally by LaunchDarkly SDK and
  # service code, where efficiency is a major concern so it's desirable to do
  # any parsing or preprocessing just once. Applications are unlikely to need
  # to use the Reference type directly.
  #
  # It can be used to retrieve a value with LDContext.get_value_for_reference()
  # or to identify an attribute or nested value that should be considered
  # private.
  #
  # Parsing and validation are done at the time that the Reference is
  # constructed. If a Reference instance was created from an invalid string, it
  # is considered invalid and its {Reference#error} attribute will return a
  # non-nil error.
  #
  # ## Syntax
  #
  # The string representation of an attribute reference in LaunchDarkly JSON
  # data uses the following syntax:
  #
  # If the first character is not a slash, the string is interpreted literally
  # as an attribute name. An attribute name can contain any characters, but
  # must not be empty.
  #
  # If the first character is a slash, the string is interpreted as a
  # slash-delimited path where the first path component is an attribute name,
  # and each subsequent path component is the name of a property in a JSON
  # object. Any instances of the characters "/" or "~" in a path component are
  # escaped as "~1" or "~0" respectively. This syntax deliberately resembles
  # JSON Pointer, but no JSON Pointer behaviors other than those mentioned here
  # are supported.
  #
  # ## Examples
  #
  # Suppose there is a context whose JSON implementation looks like this:
  #
  #	{
  #	  "kind": "user",
  #	  "key": "value1",
  #	  "address": {
  #	    "street": {
  #	      "line1": "value2",
  #	      "line2": "value3"
  #	    },
  #	    "city": "value4"
  #	  },
  #	  "good/bad": "value5"
  #	}
  #
  # The attribute references "key" and "/key" would both point to "value1".
  #
  # The attribute reference "/address/street/line1" would point to "value2".
  #
  # The attribute references "good/bad" and "/good~1bad" would both point to
  # "value5".
  #
  class Reference
    ERR_EMPTY = 'empty reference'
    private_constant :ERR_EMPTY

    ERR_INVALID_ESCAPE_SEQUENCE = 'invalid escape sequence'
    private_constant :ERR_INVALID_ESCAPE_SEQUENCE

    ERR_DOUBLE_TRAILING_SLASH = 'double or trailing slash'
    private_constant :ERR_DOUBLE_TRAILING_SLASH

    #
    # Returns nil for a valid Reference, or a non-nil error value for an
    # invalid Reference.
    #
    # A Reference is invalid if the input string is empty, or starts with a
    # slash but is not a valid slash-delimited path, or starts with a slash and
    # contains an invalid escape sequence.
    #
    # Otherwise, the Reference is valid, but that does not guarantee that such
    # an attribute exists in any given Context. For instance,
    # Reference.create("name") is a valid Reference, but a specific Context
    # might or might not have a name.
    #
    # See comments on the Reference type for more details of the attribute
    # reference syntax.
    #
    # @return [String, nil]
    #
    attr_reader :error

    #
    # Returns the attribute reference as a string, in the same format provided
    # to {#create}.
    #
    # If the Reference was created with {#create}, this value is identical to
    # the original string. If it was created with {#create_literal}, the value
    # may be different due to unescaping (for instance, an attribute whose name
    # is "/a" would be represented as "~1a").
    #
    # @return [String, nil]
    #
    attr_reader :raw_path

    def initialize(raw_path, components = [], error = nil)
      @raw_path = raw_path
      # @type [Array<Symbol>]
      @components = components
      @error = error
    end
    private_class_method :new

    protected attr_reader :components

    #
    # Creates a Reference from a string. For the supported syntax and examples,
    # see comments on the Reference type.
    #
    # This constructor always returns a Reference that preserves the original
    # string, even if validation fails, so that accessing {#raw_path} (or
    # serializing the Reference to JSON) will produce the original string. If
    # validation fails, {#error} will return a non-nil error and any SDK method
    # that takes this Reference as a parameter will consider it invalid.
    #
    # @param value [String, Symbol]
    # @return [Reference]
    #
    def self.create(value)
      unless value.is_a?(String) || value.is_a?(Symbol)
        return new(value, [], ERR_EMPTY)
      end

      value = value.to_s if value.is_a?(Symbol)

      return new(value, [], ERR_EMPTY) if value.empty? || value == "/"

      unless value.start_with? "/"
        return new(value, [value.to_sym])
      end

      if value.end_with? "/"
        return new(value, [], ERR_DOUBLE_TRAILING_SLASH)
      end

      components = []
      value[1..].split("/").each do |component|
        if component.empty?
          return new(value, [], ERR_DOUBLE_TRAILING_SLASH)
        end

        path, error = unescape_path(component)

        if error
          return new(value, [], error)
        end

        components << path.to_sym
      end

      new(value, components)
    end

    #
    # create_literal is similar to {#create} except that it always
    # interprets the string as a literal attribute name, never as a
    # slash-delimited path expression. There is no escaping or unescaping, even
    # if the name contains literal '/' or '~' characters. Since an attribute
    # name can contain any characters, this method always returns a valid
    # Reference unless the name is empty.
    #
    # For example: Reference.create_literal("name") is exactly equivalent to
    # Reference.create("name"). Reference.create_literal("a/b") is exactly
    # equivalent to Reference.create("a/b") (since the syntax used by {#create}
    # treats the whole string as a literal as long as it does not start with a
    # slash), or to Reference.create("/a~1b").
    #
    # @param value [String, Symbol]
    # @return [Reference]
    #
    def self.create_literal(value)
      unless value.is_a?(String) || value.is_a?(Symbol)
        return new(value, [], ERR_EMPTY)
      end

      value = value.to_s if value.is_a?(Symbol)

      return new(value, [], ERR_EMPTY) if value.empty?
      return new(value, [value.to_sym]) if value[0] != '/'

      escaped = "/" + value.gsub('~', '~0').gsub('/', '~1')
      new(escaped, [value.to_sym])
    end

    #
    # Returns the number of path components in the Reference.
    #
    # For a simple attribute reference such as "name" with no leading slash,
    # this returns 1.
    #
    # For an attribute reference with a leading slash, it is the number of
    # slash-delimited path components after the initial slash. For instance,
    # NewRef("/a/b").Depth() returns 2.
    #
    # @return [Integer]
    #
    def depth
      @components.size
    end

    #
    # Retrieves a single path component from the attribute reference.
    #
    # For a simple attribute reference such as "name" with no leading slash, if
    # index is zero, {#component} returns the attribute name as a symbol.
    #
    # For an attribute reference with a leading slash, if index is non-negative
    # and less than {#depth}, Component returns the path component as a symbol.
    #
    # If index is out of range, it returns nil.
    #
    #	Reference.create("a").component(0)    # returns "a"
    #	Reference.create("/a/b").component(1) # returns "b"
    #
    # @param index [Integer]
    # @return [Symbol, nil]
    #
    def component(index)
      return nil if index < 0 || index >= depth

      @components[index]
    end

    def ==(other)
      self.error == other.error && self.components == other.components
    end
    alias eql? ==

    def hash
      ([error] + components).hash
    end

    #
    # Convert the Reference to a JSON string.
    #
    # @param args [Array]
    # @return [String]
    #
    def to_json(*args)
      JSON.generate(@raw_path, *args)
    end

    #
    # Performs unescaping of attribute reference path components:
    #
    # "~1" becomes "/"
    # "~0" becomes "~"
    # "~" followed by any character other than "0" or "1" is invalid
    #
    # This method returns an array of two values. The first element of the
    # array is the path if unescaping was valid; otherwise, it will be nil. The
    # second value is an error string, or nil if the unescaping was successful.
    #
    # @param path [String]
    # @return [Array([String, nil], [String, nil])] Returns a fixed size array.
    #
    private_class_method def self.unescape_path(path)
      # If there are no tildes then there's definitely nothing to do
      return path, nil unless path.include? '~'

      out = ""
      i = 0
      while i < path.size
        if path[i] != "~"
          out << path[i]
          i += 1
          next
        end

        return nil, ERR_INVALID_ESCAPE_SEQUENCE if i + 1 == path.size

        case path[i + 1]
        when '0'
          out << "~"
        when '1'
          out << '/'
        else
          return nil, ERR_INVALID_ESCAPE_SEQUENCE
        end

        i += 2
      end

      [out, nil]
    end
  end
end
