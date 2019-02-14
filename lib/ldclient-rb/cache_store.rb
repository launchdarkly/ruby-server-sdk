require "concurrent/map"

module LaunchDarkly
  #
  # A thread-safe in-memory store that uses the same semantics that Faraday would expect, although we
  # no longer use Faraday. This is used by Requestor, when we are not in a Rails environment.
  #
  # @private
  #
  class ThreadSafeMemoryStore
    #
    # Default constructor
    #
    # @return [ThreadSafeMemoryStore] a new store
    def initialize
      @cache = Concurrent::Map.new
    end

    #
    # Read a value from the cache
    # @param key [Object] the cache key
    #
    # @return [Object] the cache value
    def read(key)
      @cache[key]
    end

    #
    # Store a value in the cache
    # @param key [Object] the cache key
    # @param value [Object] the value to associate with the key
    #
    # @return [Object] the value
    def write(key, value)
      @cache[key] = value
    end

    #
    # Delete a value in the cache
    # @param key [Object] the cache key
    def delete(key)
      @cache.delete(key)
    end
  end
end
