require "ldclient-rb/impl/util"

module LaunchDarkly
  #
  # A Result is used to reflect the outcome of any operation.
  #
  # Results can either be considered a success or a failure.
  #
  # In the event of success, the Result will contain an option, nullable value to hold any success value back to the
  # calling function.
  #
  # If the operation fails, the Result will contain an error describing the value.
  #
  class Result
    #
    # Create a successful result with the provided value.
    #
    # @param value [Object, nil]
    # @return [Result]
    #
    def self.success(value)
      Result.new(value)
    end

    #
    # Create a failed result with the provided error description.
    #
    # @param error [String]
    # @param exception [Exception, nil]
    # @return [Result]
    #
    def self.fail(error, exception = nil)
      Result.new(nil, error, exception)
    end

    #
    # Was this result successful or did it encounter an error?
    #
    # @return [Boolean]
    #
    def success?
      @error.nil?
    end

    #
    # @return [Object, nil] The value returned from the operation if it was successful; nil otherwise.
    #
    attr_reader :value

    #
    # @return [String, nil] An error description of the failure; nil otherwise
    #
    attr_reader :error

    #
    # @return [Exception, nil] An optional exception which caused the failure
    #
    attr_reader :exception

    private def initialize(value, error = nil, exception = nil)
      @value = value
      @error = error
      @exception = exception
    end
  end
end
