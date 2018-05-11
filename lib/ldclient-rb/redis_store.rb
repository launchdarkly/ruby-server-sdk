require "concurrent/atomics"
require "json"
require "thread_safe"

module LaunchDarkly
  #
  # An implementation of the LaunchDarkly client's feature store that uses a Redis
  # instance.  This object holds feature flags and related data received from the
  # streaming API.  Feature data can also be further cached in memory to reduce overhead
  # of calls to Redis.
  #
  # To use this class, you must first have the `redis` and `connection-pool` gems
  # installed.  Then, create an instance and store it in the `feature_store` property
  # of your client configuration.
  #
  class RedisFeatureStore
    begin
      require "redis"
      require "connection_pool"
      REDIS_ENABLED = true
    rescue ScriptError, StandardError
      REDIS_ENABLED = false
    end

    #
    # Constructor for a RedisFeatureStore instance.
    #
    # @param opts [Hash] the configuration options
    # @option opts [String] :redis_url  URL of the Redis instance (shortcut for omitting redis_opts)
    # @option opts [Hash] :redis_opts  options to pass to the Redis constructor (if you want to specify more than just redis_url)
    # @option opts [String] :prefix  namespace prefix to add to all hash keys used by LaunchDarkly
    # @option opts [Logger] :logger  a `Logger` instance; defaults to `Config.default_logger`
    # @option opts [Integer] :max_connections  size of the Redis connection pool
    # @option opts [Integer] :expiration  expiration time for the in-memory cache, in seconds; 0 for no local caching
    # @option opts [Integer] :capacity  maximum number of feature flags (or related objects) to cache locally
    # @option opts [Object] :pool  custom connection pool, used for testing only
    #
    def initialize(opts = {})
      if !REDIS_ENABLED
        raise RuntimeError.new("can't use RedisFeatureStore because one of these gems is missing: redis, connection_pool")
      end
      @redis_opts = opts[:redis_opts] || Hash.new
      if opts[:redis_url]
        @redis_opts[:url] = opts[:redis_url]
      end
      if !@redis_opts.include?(:url)
        @redis_opts[:url] = RedisFeatureStore.default_redis_url
      end
      max_connections = opts[:max_connections] || 16
      @pool = opts[:pool] || ConnectionPool.new(size: max_connections) do
        Redis.new(@redis_opts)
      end
      @prefix = opts[:prefix] || RedisFeatureStore.default_prefix
      @logger = opts[:logger] || Config.default_logger

      expiration_seconds = opts[:expiration] || 15
      capacity = opts[:capacity] || 1000
      if expiration_seconds > 0
        @cache = ExpiringCache.new(capacity, expiration_seconds)
      else
        @cache = nil
      end

      @stopped = Concurrent::AtomicBoolean.new(false)
      @inited = MemoizedValue.new {
        query_inited
      }

      with_connection do |redis|
        @logger.info("RedisFeatureStore: using Redis instance at #{redis.connection[:host]}:#{redis.connection[:port]} \
and prefix: #{@prefix}")
      end
    end

    #
    # Default value for the `redis_url` constructor parameter; points to an instance of Redis
    # running at `localhost` with its default port.
    #
    def self.default_redis_url
      'redis://localhost:6379/0'
    end

    #
    # Default value for the `prefix` constructor parameter.
    #
    def self.default_prefix
      'launchdarkly'
    end

    def get(kind, key)
      f = @cache.nil? ? nil : @cache[cache_key(kind, key)]
      if f.nil?
        @logger.debug { "RedisFeatureStore: no cache hit for #{key} in '#{kind[:namespace]}', requesting from Redis" }
        f = with_connection do |redis|
          begin
            get_redis(kind, redis, key.to_sym)
          rescue => e
            @logger.error { "RedisFeatureStore: could not retrieve #{key} from Redis in '#{kind[:namespace]}', with error: #{e}" }
            nil
          end
        end
      end
      if f.nil?
        @logger.debug { "RedisFeatureStore: #{key} not found in '#{kind[:namespace]}'" }
        nil
      elsif f[:deleted]
        @logger.debug { "RedisFeatureStore: #{key} was deleted in '#{kind[:namespace]}', returning nil" }
        nil
      else
        f
      end
    end

    def all(kind)
      fs = {}
      with_connection do |redis|
        begin
          hashfs = redis.hgetall(items_key(kind))
        rescue => e
          @logger.error { "RedisFeatureStore: could not retrieve all '#{kind[:namespace]}' items from Redis with error: #{e}; returning none" }
          hashfs = {}
        end
        hashfs.each do |k, jsonItem|
          f = JSON.parse(jsonItem, symbolize_names: true)
          if !f[:deleted]
            fs[k.to_sym] = f
          end
        end
      end
      fs
    end

    def delete(kind, key, version)
      update_with_versioning(kind, { key: key, version: version, deleted: true })
    end

    def init(all_data)
      @cache.clear if !@cache.nil?
      count = 0
      with_connection do |redis|
        all_data.each do |kind, items|
          begin
            redis.multi do |multi|
              multi.del(items_key(kind))
              count = count + items.count
              items.each { |key, item|
                redis.hset(items_key(kind), key, item.to_json)
              }
            end
            items.each { |key, item|
              put_cache(kind, key.to_sym, item)
            }
          rescue => e
            @logger.error { "RedisFeatureStore: could not initialize '#{kind[:namespace]}' in Redis, error: #{e}" }
          end    
        end
      end
      @inited.set(true)
      @logger.info { "RedisFeatureStore: initialized with #{count} items" }
    end

    def upsert(kind, item)
      update_with_versioning(kind, item)
    end

    def initialized?
      @inited.get
    end

    def stop
      if @stopped.make_true
        @pool.shutdown { |redis| redis.close }
        @cache.clear if !@cache.nil?
      end
    end

    private

    # exposed for testing
    def before_update_transaction(base_key, key)
    end

    def items_key(kind)
      @prefix + ":" + kind[:namespace]
    end

    def cache_key(kind, key)
      kind[:namespace] + ":" + key.to_s
    end

    def with_connection
      @pool.with { |redis| yield(redis) }
    end

    def get_redis(kind, redis, key)
      begin
        json_item = redis.hget(items_key(kind), key)
        if json_item
          item = JSON.parse(json_item, symbolize_names: true)
          put_cache(kind, key, item)
          item
        else
          nil
        end
      rescue => e
        @logger.error { "RedisFeatureStore: could not retrieve #{key} from Redis, error: #{e}" }
        nil
      end
    end

    def put_cache(kind, key, value)
      @cache[cache_key(kind, key)] = value if !@cache.nil?
    end

    def update_with_versioning(kind, new_item)
      base_key = items_key(kind)
      key = new_item[:key]
      try_again = true
      while try_again
        try_again = false
        with_connection do |redis|
          redis.watch(base_key) do
            old_item = get_redis(kind, redis, key)
            before_update_transaction(base_key, key)
            if old_item.nil? || old_item[:version] < new_item[:version]
              begin
                result = redis.multi do |multi|
                  multi.hset(base_key, key, new_item.to_json)
                end
                if result.nil?
                  @logger.debug { "RedisFeatureStore: concurrent modification detected, retrying" }
                  try_again = true
                else
                  put_cache(kind, key.to_sym, new_item)
                end
              rescue => e
                @logger.error { "RedisFeatureStore: could not store #{key} in Redis, error: #{e}" }
              end
            else
              action = new_item[:deleted] ? "delete" : "update"
              @logger.warn { "RedisFeatureStore: attempted to #{action} #{key} version: #{old_item[:version]} \
      in '#{kind[:namespace]}' with a version that is the same or older: #{new_item[:version]}" }
            end
            redis.unwatch
          end
        end
      end
    end

    def query_inited
      with_connection { |redis| redis.exists(items_key(FEATURES)) }
    end
  end
end
