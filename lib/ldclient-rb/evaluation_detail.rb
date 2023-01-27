
module LaunchDarkly
# An object returned by {LDClient#variation_detail}, combining the result of a flag evaluation with
  # an explanation of how it was calculated.
  class EvaluationDetail
    # Creates a new instance.
    #
    # @param value the result value of the flag evaluation; may be of any type
    # @param variation_index [int|nil] the index of the value within the flag's list of variations, or
    #  `nil` if the application default value was returned
    # @param reason [EvaluationReason] an object describing the main factor that influenced the result
    # @raise [ArgumentError] if `variation_index` or `reason` is not of the correct type
    def initialize(value, variation_index, reason)
      raise ArgumentError.new("variation_index must be a number") if !variation_index.nil? && !(variation_index.is_a? Numeric)
      raise ArgumentError.new("reason must be an EvaluationReason") unless reason.is_a? EvaluationReason
      @value = value
      @variation_index = variation_index
      @reason = reason
    end

    #
    # The result of the flag evaluation. This will be either one of the flag's variations, or the
    # default value that was passed to {LDClient#variation_detail}. It is the same as the return
    # value of {LDClient#variation}.
    #
    # @return [Object]
    #
    attr_reader :value

    #
    # The index of the returned value within the flag's list of variations. The first variation is
    # 0, the second is 1, etc. This is `nil` if the default value was returned.
    #
    # @return [int|nil]
    #
    attr_reader :variation_index

    #
    # An object describing the main factor that influenced the flag evaluation value.
    #
    # @return [EvaluationReason]
    #
    attr_reader :reason

    #
    # Tests whether the flag evaluation returned a default value. This is the same as checking
    # whether {#variation_index} is nil.
    #
    # @return [Boolean]
    #
    def default_value?
      variation_index.nil?
    end

    def ==(other)
      @value == other.value && @variation_index == other.variation_index && @reason == other.reason
    end
  end

  # Describes the reason that a flag evaluation produced a particular value. This is returned by
  # methods such as {LDClient#variation_detail} as the `reason` property of an {EvaluationDetail}.
  #
  # The `kind` property is always defined, but other properties will have non-nil values only for
  # certain values of `kind`. All properties are immutable.
  #
  # There is a standard JSON representation of evaluation reasons when they appear in analytics events.
  # Use `as_json` or `to_json` to convert to this representation.
  #
  # Use factory methods such as {EvaluationReason#off} to obtain instances of this class.
  class EvaluationReason
    # Value for {#kind} indicating that the flag was off and therefore returned its configured off value.
    OFF = :OFF

    # Value for {#kind} indicating that the flag was on but the context did not match any targets or rules.
    FALLTHROUGH = :FALLTHROUGH

    # Value for {#kind} indicating that the context key was specifically targeted for this flag.
    TARGET_MATCH = :TARGET_MATCH

    # Value for {#kind} indicating that the context matched one of the flag's rules.
    RULE_MATCH = :RULE_MATCH

    # Value for {#kind} indicating that the flag was considered off because it had at least one
    # prerequisite flag that either was off or did not return the desired variation.
    PREREQUISITE_FAILED = :PREREQUISITE_FAILED

    # Value for {#kind} indicating that the flag could not be evaluated, e.g. because it does not exist
    # or due to an unexpected error. In this case the result value will be the application default value
    # that the caller passed to the client. Check {#error_kind} for more details on the problem.
    ERROR = :ERROR

    # Value for {#error_kind} indicating that the caller tried to evaluate a flag before the client had
    # successfully initialized.
    ERROR_CLIENT_NOT_READY = :CLIENT_NOT_READY

    # Value for {#error_kind} indicating that the caller provided a flag key that did not match any known flag.
    ERROR_FLAG_NOT_FOUND = :FLAG_NOT_FOUND

    # Value for {#error_kind} indicating that there was an internal inconsistency in the flag data, e.g.
    # a rule specified a nonexistent  variation. An error message will always be logged in this case.
    ERROR_MALFORMED_FLAG = :MALFORMED_FLAG

    # Value for {#error_kind} indicating that the caller passed `nil` for the context parameter, or the
    # context was invalid.
    ERROR_USER_NOT_SPECIFIED = :USER_NOT_SPECIFIED

    # Value for {#error_kind} indicating that an unexpected exception stopped flag evaluation. An error
    # message will always be logged in this case.
    ERROR_EXCEPTION = :EXCEPTION

    # Indicates the general category of the reason. Will always be one of the class constants such
    # as {#OFF}.
    # @return [Symbol]
    attr_reader :kind

    # The index of the rule that was matched (0 for the first rule in the feature flag). If
    # {#kind} is not {#RULE_MATCH}, this will be `nil`.
    # @return [Integer|nil]
    attr_reader :rule_index

    # A unique string identifier for the matched rule, which will not change if other rules are added
    # or deleted. If {#kind} is not {#RULE_MATCH}, this will be `nil`.
    # @return [String]
    attr_reader :rule_id

    # A boolean or nil value representing if the rule or fallthrough has an experiment rollout.
    # @return [Boolean|nil]
    attr_reader :in_experiment

    # The key of the prerequisite flag that did not return the desired variation. If {#kind} is not
    # {#PREREQUISITE_FAILED}, this will be `nil`.
    # @return [String]
    attr_reader :prerequisite_key

    # A value indicating the general category of error. This should be one of the class constants such
    # as {#ERROR_FLAG_NOT_FOUND}. If {#kind} is not {#ERROR}, it will be `nil`.
    # @return [Symbol]
    attr_reader :error_kind

    # Describes the validity of Big Segment information, if and only if the flag evaluation required
    # querying at least one Big Segment. Otherwise it returns `nil`. Possible values are defined by
    # {BigSegmentsStatus}.
    #
    # Big Segments are a specific kind of context segments. For more information, read the LaunchDarkly
    # documentation: https://docs.launchdarkly.com/home/users/big-segments
    # @return [Symbol]
    attr_reader :big_segments_status

    # Returns an instance whose {#kind} is {#OFF}.
    # @return [EvaluationReason]
    def self.off
      @@off
    end

    # Returns an instance whose {#kind} is {#FALLTHROUGH}.
    # @return [EvaluationReason]
    def self.fallthrough(in_experiment=false)
      if in_experiment
        @@fallthrough_with_experiment
      else
        @@fallthrough
      end
    end

    # Returns an instance whose {#kind} is {#TARGET_MATCH}.
    # @return [EvaluationReason]
    def self.target_match
      @@target_match
    end

    # Returns an instance whose {#kind} is {#RULE_MATCH}.
    #
    # @param rule_index [Number] the index of the rule that was matched (0 for the first rule in
    #   the feature flag)
    # @param rule_id [String] unique string identifier for the matched rule
    # @return [EvaluationReason]
    # @raise [ArgumentError] if `rule_index` is not a number or `rule_id` is not a string
    def self.rule_match(rule_index, rule_id, in_experiment=false)
      raise ArgumentError.new("rule_index must be a number") unless rule_index.is_a? Numeric
      raise ArgumentError.new("rule_id must be a string") if !rule_id.nil? && !(rule_id.is_a? String) # in test data, ID could be nil

      if in_experiment
        er = new(:RULE_MATCH, rule_index, rule_id, nil, nil, true)
      else
        er = new(:RULE_MATCH, rule_index, rule_id, nil, nil)
      end
      er
    end

    # Returns an instance whose {#kind} is {#PREREQUISITE_FAILED}.
    #
    # @param prerequisite_key [String] key of the prerequisite flag that did not return the desired variation
    # @return [EvaluationReason]
    # @raise [ArgumentError] if `prerequisite_key` is nil or not a string
    def self.prerequisite_failed(prerequisite_key)
      raise ArgumentError.new("prerequisite_key must be a string") unless prerequisite_key.is_a? String
      new(:PREREQUISITE_FAILED, nil, nil, prerequisite_key, nil)
    end

    # Returns an instance whose {#kind} is {#ERROR}.
    #
    # @param error_kind [Symbol] value indicating the general category of error
    # @return [EvaluationReason]
    # @raise [ArgumentError] if `error_kind` is not a symbol
    def self.error(error_kind)
      raise ArgumentError.new("error_kind must be a symbol") unless error_kind.is_a? Symbol
      e = @@error_instances[error_kind]
      e.nil? ? make_error(error_kind) : e
    end

    def ==(other)
      if other.is_a? EvaluationReason
        @kind == other.kind && @rule_index == other.rule_index && @rule_id == other.rule_id &&
          @prerequisite_key == other.prerequisite_key && @error_kind == other.error_kind &&
          @big_segments_status == other.big_segments_status
      elsif other.is_a? Hash
        @kind.to_s == other[:kind] && @rule_index == other[:ruleIndex] && @rule_id == other[:ruleId] &&
          @prerequisite_key == other[:prerequisiteKey] &&
          (other[:errorKind] == @error_kind.nil? ? nil : @error_kind.to_s) &&
          (other[:bigSegmentsStatus] == @big_segments_status.nil? ? nil : @big_segments_status.to_s)
      end
    end

    # Equivalent to {#inspect}.
    # @return [String]
    def to_s
      inspect
    end

    # Returns a concise string representation of the reason. Examples: `"FALLTHROUGH"`,
    # `"ERROR(FLAG_NOT_FOUND)"`. The exact syntax is not guaranteed to remain the same; this is meant
    # for debugging.
    # @return [String]
    def inspect
      case @kind
      when :RULE_MATCH
        if @in_experiment
          "RULE_MATCH(#{@rule_index},#{@rule_id},#{@in_experiment})"
        else
          "RULE_MATCH(#{@rule_index},#{@rule_id})"
        end
      when :PREREQUISITE_FAILED
        "PREREQUISITE_FAILED(#{@prerequisite_key})"
      when :ERROR
        "ERROR(#{@error_kind})"
      when :FALLTHROUGH
        @in_experiment ? "FALLTHROUGH(#{@in_experiment})" : @kind.to_s
      else
        @kind.to_s
      end
    end

    # Returns a hash that can be used as a JSON representation of the reason, in the format used
    # in LaunchDarkly analytics events.
    # @return [Hash]
    def as_json(*) # parameter is unused, but may be passed if we're using the json gem
      # Note that this implementation is somewhat inefficient; it allocates a new hash every time.
      # However, in normal usage the SDK only serializes reasons if 1. full event tracking is
      # enabled for a flag and the application called variation_detail, or 2. experimentation is
      # enabled for an evaluation. We can't reuse these hashes because an application could call
      # as_json and then modify the result.
      ret = case @kind
      when :RULE_MATCH
        if @in_experiment
          { kind: @kind, ruleIndex: @rule_index, ruleId: @rule_id, inExperiment: @in_experiment }
        else
          { kind: @kind, ruleIndex: @rule_index, ruleId: @rule_id }
        end
      when :PREREQUISITE_FAILED
        { kind: @kind, prerequisiteKey: @prerequisite_key }
      when :ERROR
        { kind: @kind, errorKind: @error_kind }
      when :FALLTHROUGH
        if @in_experiment
          { kind: @kind, inExperiment: @in_experiment }
        else
          { kind: @kind }
        end
      else
        { kind: @kind }
      end
      unless @big_segments_status.nil?
        ret[:bigSegmentsStatus] = @big_segments_status
      end
      ret
    end

    # Same as {#as_json}, but converts the JSON structure into a string.
    # @return [String]
    def to_json(*a)
      as_json.to_json(*a)
    end

    # Allows this object to be treated as a hash corresponding to its JSON representation. For
    # instance, if `reason.kind` is {#RULE_MATCH}, then `reason[:kind]` will be `"RULE_MATCH"` and
    # `reason[:ruleIndex]` will be equal to `reason.rule_index`.
    def [](key)
      case key
      when :kind
        @kind.to_s
      when :ruleIndex
        @rule_index
      when :ruleId
        @rule_id
      when :prerequisiteKey
        @prerequisite_key
      when :errorKind
        @error_kind.nil? ? nil : @error_kind.to_s
      when :bigSegmentsStatus
        @big_segments_status.nil? ? nil : @big_segments_status.to_s
      else
        nil
      end
    end

    def with_big_segments_status(big_segments_status)
      return self if @big_segments_status == big_segments_status
      EvaluationReason.new(@kind, @rule_index, @rule_id, @prerequisite_key, @error_kind, @in_experiment, big_segments_status)
    end

    #
    # Constructor that sets all properties. Applications should not normally use this constructor,
    # but should use class methods like {#off} to avoid creating unnecessary instances.
    #
    def initialize(kind, rule_index, rule_id, prerequisite_key, error_kind, in_experiment=nil,
        big_segments_status = nil)
      @kind = kind.to_sym
      @rule_index = rule_index
      @rule_id = rule_id
      @rule_id.freeze unless rule_id.nil?
      @prerequisite_key = prerequisite_key
      @prerequisite_key.freeze unless prerequisite_key.nil?
      @error_kind = error_kind
      @in_experiment = in_experiment
      @big_segments_status = big_segments_status
    end

    private_class_method def self.make_error(error_kind)
      new(:ERROR, nil, nil, nil, error_kind)
    end

    @@fallthrough_with_experiment = new(:FALLTHROUGH, nil, nil, nil, nil, true)
    @@fallthrough = new(:FALLTHROUGH, nil, nil, nil, nil)
    @@off = new(:OFF, nil, nil, nil, nil)
    @@target_match = new(:TARGET_MATCH, nil, nil, nil, nil)
    @@error_instances = {
      ERROR_CLIENT_NOT_READY => make_error(ERROR_CLIENT_NOT_READY),
      ERROR_FLAG_NOT_FOUND => make_error(ERROR_FLAG_NOT_FOUND),
      ERROR_MALFORMED_FLAG => make_error(ERROR_MALFORMED_FLAG),
      ERROR_USER_NOT_SPECIFIED => make_error(ERROR_USER_NOT_SPECIFIED),
      ERROR_EXCEPTION => make_error(ERROR_EXCEPTION),
    }
  end

  #
  # Defines the possible values of {EvaluationReason#big_segments_status}.
  #
  module BigSegmentsStatus
    #
    # Indicates that the Big Segment query involved in the flag evaluation was successful, and
    # that the segment state is considered up to date.
    #
    HEALTHY = :HEALTHY

    #
    # Indicates that the Big Segment query involved in the flag evaluation was successful, but
    # that the segment state may not be up to date.
    #
    STALE = :STALE

    #
    # Indicates that Big Segments could not be queried for the flag evaluation because the SDK
    # configuration did not include a Big Segment store.
    #
    NOT_CONFIGURED = :NOT_CONFIGURED

    #
    # Indicates that the Big Segment query involved in the flag evaluation failed, for instance
    # due to a database error.
    #
    STORE_ERROR = :STORE_ERROR
  end
end
