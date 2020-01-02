
module LaunchDarkly
# An object returned by {LDClient#variation_detail}, combining the result of a flag evaluation with
  # an explanation of how it was calculated.
  class EvaluationDetail
    def initialize(value, variation_index, reason)
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
    # This object is currently represented as a Hash, which may have the following keys:
    #
    # `:kind`: The general category of reason. Possible values:
    #
    # * `'OFF'`: the flag was off and therefore returned its configured off value
    # * `'FALLTHROUGH'`: the flag was on but the user did not match any targets or rules
    # * `'TARGET_MATCH'`: the user key was specifically targeted for this flag
    # * `'RULE_MATCH'`: the user matched one of the flag's rules
    # * `'PREREQUISITE_FAILED`': the flag was considered off because it had at least one
    # prerequisite flag that either was off or did not return the desired variation
    # * `'ERROR'`: the flag could not be evaluated, so the default value was returned
    #
    # `:ruleIndex`: If the kind was `RULE_MATCH`, this is the positional index of the
    # matched rule (0 for the first rule).
    #
    # `:ruleId`: If the kind was `RULE_MATCH`, this is the rule's unique identifier.
    #
    # `:prerequisiteKey`: If the kind was `PREREQUISITE_FAILED`, this is the flag key of
    # the prerequisite flag that failed.
    #
    # `:errorKind`: If the kind was `ERROR`, this indicates the type of error:
    #
    # * `'CLIENT_NOT_READY'`: the caller tried to evaluate a flag before the client had
    # successfully initialized
    # * `'FLAG_NOT_FOUND'`: the caller provided a flag key that did not match any known flag
    # * `'MALFORMED_FLAG'`: there was an internal inconsistency in the flag data, e.g. a
    # rule specified a nonexistent variation
    # * `'USER_NOT_SPECIFIED'`: the user object or user key was not provied
    # * `'EXCEPTION'`: an unexpected exception stopped flag evaluation
    #
    # @return [Hash]
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
end
