require 'logger'

module LaunchDarkly

  # 
  # This class exposes advanced configuration options for the LaunchDarkly client library. Most users
  # will not need to use a custom configuration-- the default configuration sets sane defaults for most use cases. 
  # 
  #   
  class Config
    # 
    # Constructor for creating custom LaunchDarkly configurations. 
    # 
    # @param opts [Hash] the configuration options
    # @option opts [Logger] :logger A logger to use for messages from the LaunchDarkly client. Defaults to the Rails logger in a Rails environment, or stdout otherwise.
    # @option opts [String] :base_uri ("https://app.launchdarkly.com") The base URL for the LaunchDarkly server. Most users should use the default value.
    # @option opts [Integer] :capacity (10000) The capacity of the events buffer. The client buffers up to this many events in memory before flushing. If the capacity is exceeded before the buffer is flushed, events will be discarded.
    # @option opts [Integer] :flush_interval (30) The number of seconds between flushes of the event buffer. 
    # @option opts [Object] :store A cache store for the Faraday HTTP caching library. Defaults to the Rails cache in a Rails environment, or a thread-safe in-memory store otherwise.
    # 
    # @return [type] [description]
    def initialize(opts = {})
      @base_uri = (opts[:base_uri] || Config.default_base_uri).chomp("/")
      @capacity = opts[:capacity] || Config.default_capacity
      @logger = opts[:logger] || Config.default_logger
      @store = opts[:store] || Config.default_store
      @flush_interval = opts[:flush_interval] || Config.default_flush_interval
    end

    # 
    # The base URL for the LaunchDarkly server.
    # 
    # @return [String] The configured base URL for the LaunchDarkly server.
    def base_uri
      @base_uri
    end

    # 
    # The number of seconds between flushes of the event buffer. Decreasing the flush interval means
    # that the event buffer is less likely to reach capacity.
    # 
    # @return [Integer] The configured number of seconds between flushes of the event buffer.
    def flush_interval
      @flush_interval
    end

    # 
    # The configured logger for the LaunchDarkly client. The client library uses the log to
    # print warning and error messages. 
    # 
    # @return [Logger] The configured logger
    def logger
      @logger
    end

    # 
    # The capacity of the events buffer. The client buffers up to this many events in memory before flushing. If the capacity is exceeded before the buffer is flushed, events will be discarded.
    # Increasing the capacity means that events are less likely to be discarded, at the cost of consuming more memory.
    # 
    # @return [Integer] The configured capacity of the event buffer
    def capacity
      @capacity
    end

    # 
    # The store for the Faraday HTTP caching library. Stores should respond to 'read' and 'write' requests.
    # 
    # @return [Object] The configured store for the Faraday HTTP caching library.
    def store
      @store
    end

    # 
    # The default LaunchDarkly client configuration. This configuration sets reasonable defaults for most users.
    # 
    # @return [Config] The default LaunchDarkly configuration.
    def self.default
      Config.new()
    end

    def self.default_capacity
      10000
    end

    def self.default_base_uri
      "https://app.launchdarkly.com"
    end

    def self.default_store
      defined?(Rails) && Rails.respond_to?(:cache) ? Rails.cache : ThreadSafeMemoryStore.new
    end    

    def self.default_flush_interval
      10
    end

    def self.default_logger
      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : ::Logger.new($stdout)
    end

  end
end