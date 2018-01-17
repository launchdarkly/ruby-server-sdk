require "concurrent/atomics"
require "json"
require "thread_safe"

module LaunchDarkly
  #
  # Base class for all Redis versioned object stores.
  #
  class RedisVersionedStore
    begin
      require "redis"
      require "connection_pool"
      require "moneta"
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
    # @option opts [Integer] :capacity  maximum number of feature flags to cache locally
    # @option opts [Object] :pool  custom connection pool, used for testing only
    #
    def initialize(opts = {})
      if !REDIS_ENABLED
        raise RuntimeError.new("can't use #{storeName} because one of these gems is missing: redis, connection_pool, moneta")
      end
      @redis_opts = opts[:redis_opts] || Hash.new
      if opts[:redis_url]
        @redis_opts[:url] = opts[:redis_url]
      end
      if !@redis_opts.include?(:url)
        @redis_opts[:url] = RedisVersionedStore.default_redis_url
      end
      max_connections = opts[:max_connections] || 16
      @pool = opts[:pool] || ConnectionPool.new(size: max_connections) do
        Redis.new(@redis_opts)
      end
      @prefix = opts[:prefix] || RedisVersionedStore.default_prefix
      @logger = opts[:logger] || Config.default_logger
      @items_key = @prefix + baseKeySuffix

      @expiration_seconds = opts[:expiration] || 15
      @capacity = opts[:capacity] || 1000
      # We're using Moneta only to provide expiration behavior for the in-memory cache.
      # Moneta can also be used as a wrapper for Redis, but it doesn't support the Redis
      # hash operations that we use.
      if @expiration_seconds > 0
        @cache = Moneta.new(:LRUHash, expires: true, threadsafe: true, max_count: @capacity)
      else
        @cache = Moneta.new(:Null)  # a stub that caches nothing
      end

      @stopped = Concurrent::AtomicBoolean.new(false)
      @inited = MemoizedValue.new {
        query_inited
      }

      with_connection do |redis|
        @logger.info("#{storeName}: using Redis instance at #{redis.connection[:host]}:#{redis.connection[:port]} \
and prefix: #{@prefix}")
      end
    end

    def baseKeySuffix
    end

    def storeName
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

    def get(key)
      f = @cache[key.to_sym]
      if f.nil?
        @logger.debug("#{storeName}: no cache hit for #{key}, requesting from Redis")
        f = with_connection do |redis|
          begin
            get_redis(redis,key.to_sym)
          rescue => e
            @logger.error("#{storeName}: could not retrieve #{key} from Redis, with error: #{e}")
            nil
          end
        end
        if !f.nil?
          put_cache(key.to_sym, f)
        end
      end
      if f.nil?
        @logger.warn("#{storeName}: #{key} not found")
        nil
      elsif f[:deleted]
        @logger.warn("#{storeName}: #{key} was deleted, returning nil")
        nil
      else
        f
      end
    end

    def all
      fs = {}
      with_connection do |redis|
        begin
          hashfs = redis.hgetall(@items_key)
        rescue => e
          @logger.error("#{storeName}: could not retrieve all items from Redis with error: #{e}; returning none")
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

    def delete(key, version)
      with_connection do |redis|
        f = get_redis(redis, key)
        if f.nil?
          put_redis_and_cache(redis, key, { deleted: true, version: version })
        else
          if f[:version] < version
            f1 = f.clone
            f1[:deleted] = true
            f1[:version] = version
            put_redis_and_cache(redis, key, f1)
          else
            @logger.warn("#{storeName}: attempted to delete #{key} version: #{f[:version]} \
  with a version that is the same or older: #{version}")
          end
        end
      end
    end

    def init(fs)
      @cache.clear
      with_connection do |redis|
        redis.multi do |multi|
          redis.del(@items_key)
          fs.each { |k, f| put_redis_and_cache(multi, k, f) }
        end
      end
      @inited.set(true)
      @logger.info("#{storeName}: initialized with #{fs.count} items")
    end

    def upsert(key, item)
      with_connection do |redis|
        redis.watch(@items_key) do
          old = get_redis(redis, key)
          if old.nil? || (old[:version] < item[:version])
            put_redis_and_cache(redis, key, item)
          end
          redis.unwatch
        end
      end
    end

    def initialized?
      @inited.get
    end

    def stop
      if @stopped.make_true
        @pool.shutdown { |redis| redis.close }
        @cache.clear
      end
    end

    # exposed for testing
    def clear_local_cache()
      @cache.clear
    end

    private

    def with_connection
      @pool.with { |redis| yield(redis) }
    end

    def get_redis(redis, key)
      begin
        json_item = redis.hget(@items_key, key)
        JSON.parse(json_item, symbolize_names: true) if json_item
      rescue => e
        @logger.error("#{storeName}: could not retrieve #{key} from Redis, error: #{e}")
        nil
      end
    end

    def put_cache(key, value)
      @cache.store(key, value, expires: @expiration_seconds)
    end

    def put_redis_and_cache(redis, key, item)
      begin
        redis.hset(@items_key, key, item.to_json)
      rescue => e
        @logger.error("#{storeName}: could not store #{key} in Redis, error: #{e}")
      end
      put_cache(key.to_sym, item)
    end

    def query_inited
      with_connection { |redis| redis.exists(@items_key) }
    end
  end

  #
  # An implementation of the LaunchDarkly client's feature store that uses a Redis
  # instance.  Feature data can also be further cached in memory to reduce overhead
  # of calls to Redis.
  #
  # To use this class, you must first have the `redis`, `connection-pool`, and `moneta`
  # gems installed.  Then, create an instance and store it in the `feature_store`
  # property of your client configuration.
  #
  class RedisFeatureStore < RedisVersionedStore
    def baseKeySuffix
      ':features'
    end

    def storeName
      'RedisFeatureStore'
    end
  end

  #
  # An implementation of the LaunchDarkly client's segment store that uses a Redis
  # instance.  Segment data can also be further cached in memory to reduce overhead
  # of calls to Redis.
  #
  # To use this class, you must first have the `redis`, `connection-pool`, and `moneta`
  # gems installed.  Then, create an instance and store it in the `segment_store`
  # property of your client configuration.
  #
  class RedisSegmentStore < RedisVersionedStore
    def baseKeySuffix
      ':segments'
    end

    def storeName
      'RedisSegmentStore'
    end
  end
end
