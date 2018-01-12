
module LaunchDarkly
  # Simple implementation of a thread-safe memoized value whose generator function will never be
  # run more than once, and whose value can be overridden by explicit assignment.
  class MemoizedValue
    def initialize(&generator)
      @generator = generator
      @mutex = Mutex.new
      @inited = false
      @value = nil
    end

    def get
      @mutex.synchronize do
        if !@inited
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
