require "ldclient-rb/impl/util"

module LaunchDarkly
  module Impl
    # A thread-safe cache with maximum number of entries and TTL.
    # Adapted from https://github.com/SamSaffron/lru_redux/blob/master/lib/lru_redux/ttl/cache.rb
    # under MIT license with the following changes:
    #   * made thread-safe
    #   * removed many unused methods
    #   * reading a key does not reset its expiration time, only writing
    #   * expiration is measured on a monotonic clock, so wall-clock steps cannot
    #     retain entries past their TTL or evict them early
    class ExpiringCache
      MONOTONIC_CLOCK = -> { Impl::Util.monotonic_seconds }
      private_constant :MONOTONIC_CLOCK

      # @param clock [#call] returns seconds on a monotonic clock; injectable for tests
      def initialize(max_size, ttl, clock: MONOTONIC_CLOCK)
        @max_size = max_size
        @ttl = ttl
        @clock = clock
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
          @data_ttl[key] = @clock.call

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
        ttl_horizon = @clock.call - @ttl
        key, time = @data_ttl.first

        until time.nil? || time > ttl_horizon
          @data_ttl.delete(key)
          @data_lru.delete(key)

          key, time = @data_ttl.first
        end
      end
    end
  end
end

