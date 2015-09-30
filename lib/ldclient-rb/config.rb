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
    # @option opts [Float] :flush_interval (30) The number of seconds between flushes of the event buffer.
    # @option opts [Float] :read_timeout (10) The read timeout for network connections in seconds.
    # @option opts [Float] :connect_timeout (2) The connect timeout for network connections in seconds.
    # @option opts [Object] :store A cache store for the Faraday HTTP caching library. Defaults to the Rails cache in a Rails environment, or a thread-safe in-memory store otherwise.
    #
    # @return [type] [description]
    def initialize(opts = {})
      @base_uri = (opts[:base_uri] || Config.default_base_uri).chomp("/")
      @stream_uri = (opts[:stream_uri] || Config.default_stream_uri).chomp("/")
      @capacity = opts[:capacity] || Config.default_capacity
      @logger = opts[:logger] || Config.default_logger
      @store = opts[:store] || Config.default_store
      @flush_interval = opts[:flush_interval] || Config.default_flush_interval
      @connect_timeout = opts[:connect_timeout] || Config.default_connect_timeout
      @read_timeout = opts[:read_timeout] || Config.default_read_timeout
      @log_timings = opts[:log_timings] || Config.default_log_timings
      @stream = opts[:stream] || Config.default_stream
      @feature_store = opts[:feature_store] || Config.default_feature_store
      @debug_stream = opts[:debug_stream] || Config.default_debug_stream
    end

    #
    # The base URL for the LaunchDarkly server.
    #
    # @return [String] The configured base URL for the LaunchDarkly server.
    def base_uri
      @base_uri
    end

    #
    # The base URL for the LaunchDarkly streaming server.
    #
    # @return [String] The configured base URL for the LaunchDarkly streaming server.
    def stream_uri
      @stream_uri
    end

    #
    # Whether streaming mode should be enabled. Streaming mode asynchronously updates
    # feature flags in real-time using server-sent events.
    #
    # @return [Boolean] True if streaming mode should be enabled
    def stream?
      @stream
    end

    #
    # Whether we should debug streaming mode. If set, the client will fetch features via polling
    # and compare the retrieved feature with the value in the feature store
    #
    # @return [Boolean] True if we should debug streaming mode
    def debug_stream?
      @debug_stream
    end

    #
    # The number of seconds between flushes of the event buffer. Decreasing the flush interval means
    # that the event buffer is less likely to reach capacity.
    #
    # @return [Float] The configured number of seconds between flushes of the event buffer.
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
    # The read timeout for network connections in seconds.
    #
    # @return [Float] The read timeout in seconds.
    def read_timeout
      @read_timeout
    end

    #
    # The connect timeout for network connections in seconds.
    #
    # @return [Float] The connect timeout in seconds.
    def connect_timeout
      @connect_timeout
    end

    #
    # Whether timing information should be logged. If it is logged, it will be logged to the DEBUG
    # level on the configured logger.  This can be very verbose.
    #
    # @return [Boolean] True if timing information should be logged.
    def log_timings?
      @log_timings
    end

    #
    # TODO docs
    #
    def feature_store
      @feature_store
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

    def self.default_stream_uri
      "https://stream.launchdarkly.com"
    end

    def self.default_store
      defined?(Rails) && Rails.respond_to?(:cache) ? Rails.cache : ThreadSafeMemoryStore.new
    end

    def self.default_flush_interval
      10
    end

    def self.default_read_timeout
      10
    end

    def self.default_connect_timeout
      2
    end

    def self.default_logger
      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : ::Logger.new($stdout)
    end

    def self.default_log_timings
      false
    end

    def self.default_stream
      true
    end

    def self.default_feature_store
      nil
    end

    def self.default_debug_stream
      false
    end

  end
end
