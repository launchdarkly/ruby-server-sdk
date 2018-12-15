
module LaunchDarkly
  # A thread-safe cache with maximum number of entries and TTL.
  # Adapted from https://github.com/SamSaffron/lru_redux/blob/master/lib/lru_redux/ttl/cache.rb
  # under MIT license with the following changes:
  #   * made thread-safe
  #   * removed many unused methods
  #   * reading a key does not reset its expiration time, only writing
  # @private
  class ExpiringCache
    def initialize(max_size, ttl)
      @max_size = max_size
      @ttl = ttl
      @data_lru = {}
      @data_ttl = {}
      @lock = Mutex.new
    end

    def [](key)
      @lock.synchronize do
        ttl_evict
        @data_lru[key]
      end
    end

    def []=(key, val)
      @lock.synchronize do
        ttl_evict

        @data_lru.delete(key)
        @data_ttl.delete(key)

        @data_lru[key] = val
        @data_ttl[key] = Time.now.to_f

        if @data_lru.size > @max_size
          key, _ = @data_lru.first # hashes have a FIFO ordering in Ruby

          @data_ttl.delete(key)
          @data_lru.delete(key)
        end

        val
      end
    end

    def delete(key)
      @lock.synchronize do
        ttl_evict

        @data_lru.delete(key)
        @data_ttl.delete(key)
      end
    end

    def clear
      @lock.synchronize do
        @data_lru.clear
        @data_ttl.clear
      end
    end

    private

    def ttl_evict
      ttl_horizon = Time.now.to_f - @ttl
      key, time = @data_ttl.first

      until time.nil? || time > ttl_horizon
        @data_ttl.delete(key)
        @data_lru.delete(key)

        key, time = @data_ttl.first
      end
    end
  end
end
