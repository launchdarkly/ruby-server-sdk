
module LaunchDarkly
  # Simple implementation of a thread-safe memoized value whose generator function will never be
  # run more than once, and whose value can be overridden by explicit assignment.
  # Note that we no longer use this class and it will be removed in a future version.
  # @private
  class MemoizedValue
    def initialize(&generator)
      @generator = generator
      @mutex = Mutex.new
      @inited = false
      @value = nil
    end

    def get
      @mutex.synchronize do
        unless @inited
          @value = @generator.call
          @inited = true
        end
      end
      @value
    end

    def set(value)
      @mutex.synchronize do
        @value = value
        @inited = true
      end
    end
  end
end
