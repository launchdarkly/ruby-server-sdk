require "logger"

module LaunchDarkly
  #
  # This class exposes advanced configuration options for the LaunchDarkly
  # client library. Most users will not need to use a custom configuration--
  # the default configuration sets sane defaults for most use cases.
  #
  #
  class Config
    # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity

    #
    # Constructor for creating custom LaunchDarkly configurations.
    #
    # @param opts [Hash] the configuration options
    # @option opts [Logger] :logger See {#logger}.
    # @option opts [String] :base_uri ("https://sdk.launchdarkly.com") See {#base_uri}.
    # @option opts [String] :stream_uri ("https://stream.launchdarkly.com") See {#stream_uri}.
    # @option opts [String] :events_uri ("https://events.launchdarkly.com") See {#events_uri}.
    # @option opts [Integer] :capacity (10000) See {#capacity}.
    # @option opts [Float] :flush_interval (30) See {#flush_interval}.
    # @option opts [Float] :read_timeout (10) See {#read_timeout}.
    # @option opts [Float] :connect_timeout (2) See {#connect_timeout}.
    # @option opts [Object] :cache_store See {#cache_store}.
    # @option opts [Object] :feature_store See {#feature_store}.
    # @option opts [Boolean] :use_ldd (false) See {#use_ldd?}.
    # @option opts [Boolean] :offline (false) See {#offline?}.
    # @option opts [Float] :poll_interval (30) See {#poll_interval}.
    # @option opts [Boolean] :stream (true) See {#stream?}.
    # @option opts [Boolean] all_attributes_private (false) See {#all_attributes_private}.
    # @option opts [Array] :private_attribute_names See {#private_attribute_names}.
    # @option opts [Boolean] :send_events (true) See {#send_events}.
    # @option opts [Integer] :user_keys_capacity (1000) See {#user_keys_capacity}.
    # @option opts [Float] :user_keys_flush_interval (300) See {#user_keys_flush_interval}.
    # @option opts [Boolean] :inline_users_in_events (false) See {#inline_users_in_events}.
    # @option opts [Object] :data_source See {#data_source}.
    # @option opts [Object] :update_processor Obsolete synonym for `data_source`.
    # @option opts [Object] :update_processor_factory Obsolete synonym for `data_source`.
    # @option opts [Boolean] :diagnostic_opt_out (false) See {#diagnostic_opt_out?}.
    # @option opts [Float] :diagnostic_recording_interval (900) See {#diagnostic_recording_interval}.
    # @option opts [String] :wrapper_name See {#wrapper_name}.
    # @option opts [String] :wrapper_version See {#wrapper_version}.
    # @option opts [#open] :socket_factory See {#socket_factory}.
    #
    def initialize(opts = {})
      @base_uri = (opts[:base_uri] || Config.default_base_uri).chomp("/")
      @stream_uri = (opts[:stream_uri] || Config.default_stream_uri).chomp("/")
      @events_uri = (opts[:events_uri] || Config.default_events_uri).chomp("/")
      @capacity = opts[:capacity] || Config.default_capacity
      @logger = opts[:logger] || Config.default_logger
      @cache_store = opts[:cache_store] || Config.default_cache_store
      @flush_interval = opts[:flush_interval] || Config.default_flush_interval
      @connect_timeout = opts[:connect_timeout] || Config.default_connect_timeout
      @read_timeout = opts[:read_timeout] || Config.default_read_timeout
      @feature_store = opts[:feature_store] || Config.default_feature_store
      @stream = opts.has_key?(:stream) ? opts[:stream] : Config.default_stream
      @use_ldd = opts.has_key?(:use_ldd) ? opts[:use_ldd] : Config.default_use_ldd
      @offline = opts.has_key?(:offline) ? opts[:offline] : Config.default_offline
      @poll_interval = opts.has_key?(:poll_interval) && opts[:poll_interval] > Config.default_poll_interval ? opts[:poll_interval] : Config.default_poll_interval
      @all_attributes_private = opts[:all_attributes_private] || false
      @private_attribute_names = opts[:private_attribute_names] || []
      @send_events = opts.has_key?(:send_events) ? opts[:send_events] : Config.default_send_events
      @user_keys_capacity = opts[:user_keys_capacity] || Config.default_user_keys_capacity
      @user_keys_flush_interval = opts[:user_keys_flush_interval] || Config.default_user_keys_flush_interval
      @inline_users_in_events = opts[:inline_users_in_events] || false
      @data_source = opts[:data_source] || opts[:update_processor] || opts[:update_processor_factory]
      @update_processor = opts[:update_processor]
      @update_processor_factory = opts[:update_processor_factory]
      @diagnostic_opt_out = opts.has_key?(:diagnostic_opt_out) && opts[:diagnostic_opt_out]
      @diagnostic_recording_interval = opts.has_key?(:diagnostic_recording_interval) && opts[:diagnostic_recording_interval] > Config.minimum_diagnostic_recording_interval ?
        opts[:diagnostic_recording_interval] : Config.default_diagnostic_recording_interval
      @wrapper_name = opts[:wrapper_name]
      @wrapper_version = opts[:wrapper_version]
      @socket_factory = opts[:socket_factory]
    end

    #
    # The base URL for the LaunchDarkly server. This is configurable mainly for testing
    # purposes; most users should use the default value.
    # @return [String]
    #
    attr_reader :base_uri

    #
    # The base URL for the LaunchDarkly streaming server. This is configurable mainly for testing
    # purposes; most users should use the default value.
    # @return [String]
    #
    attr_reader :stream_uri

    #
    # The base URL for the LaunchDarkly events server. This is configurable mainly for testing
    # purposes; most users should use the default value.
    # @return [String]
    #
    attr_reader :events_uri

    #
    # Whether streaming mode should be enabled. Streaming mode asynchronously updates
    # feature flags in real-time using server-sent events. Streaming is enabled by default, and
    # should only be disabled on the advice of LaunchDarkly support.
    # @return [Boolean]
    #
    def stream?
      @stream
    end

    #
    # Whether to use the LaunchDarkly relay proxy in daemon mode. In this mode, the client does not
    # use polling or streaming to get feature flag updates from the server, but instead reads them
    # from the {#feature_store feature store}, which is assumed to be a database that is populated by
    # a LaunchDarkly relay proxy. For more information, see ["The relay proxy"](https://docs.launchdarkly.com/v2.0/docs/the-relay-proxy)
    # and ["Using a persistent feature store"](https://docs.launchdarkly.com/v2.0/docs/using-a-persistent-feature-store).
    #
    # All other properties related to streaming or polling are ignored if this option is set to true.
    #
    # @return [Boolean]
    #
    def use_ldd?
      @use_ldd
    end
    
    #
    # Whether the client should be initialized in offline mode. In offline mode, default values are
    # returned for all flags and no remote network requests are made.
    # @return [Boolean]
    #
    def offline?
      @offline
    end

    #
    # The number of seconds between flushes of the event buffer. Decreasing the flush interval means
    # that the event buffer is less likely to reach capacity.
    # @return [Float]
    #
    attr_reader :flush_interval

    #
    # The number of seconds to wait before polling for feature flag updates. This option has no
    # effect unless streaming is disabled.
    # @return [Float]
    #
    attr_reader :poll_interval

    #
    # The configured logger for the LaunchDarkly client. The client library uses the log to
    # print warning and error messages. If not specified, this defaults to the Rails logger
    # in a Rails environment, or stdout otherwise.
    # @return [Logger]
    #
    attr_reader :logger

    #
    # The capacity of the events buffer. The client buffers up to this many
    # events in memory before flushing. If the capacity is exceeded before
    # the buffer is flushed, events will be discarded.
    # Increasing the capacity means that events are less likely to be discarded,
    # at the cost of consuming more memory.
    # @return [Integer]
    #
    attr_reader :capacity

    #
    # A store for HTTP caching (used only in polling mode). This must support the semantics used by
    # the [`faraday-http-cache`](https://github.com/plataformatec/faraday-http-cache) gem, although
    # the SDK no longer uses Faraday. Defaults to the Rails cache in a Rails environment, or a
    # thread-safe in-memory store otherwise.
    # @return [Object]
    #
    attr_reader :cache_store

    #
    # The read timeout for network connections in seconds. This does not apply to the streaming
    # connection, which uses a longer timeout since the server does not send data constantly.
    # @return [Float]
    #
    attr_reader :read_timeout

    #
    # The connect timeout for network connections in seconds.
    # @return [Float]
    #
    attr_reader :connect_timeout

    #
    # A store for feature flags and related data. The client uses it to store all data received
    # from LaunchDarkly, and uses the last stored data when evaluating flags. Defaults to
    # {InMemoryFeatureStore}; for other implementations, see {LaunchDarkly::Integrations}.
    #
    # For more information, see ["Using a persistent feature store"](https://docs.launchdarkly.com/v2.0/docs/using-a-persistent-feature-store).
    #
    # @return [LaunchDarkly::Interfaces::FeatureStore]
    #
    attr_reader :feature_store

    #
    # True if all user attributes (other than the key) should be considered private. This means
    # that the attribute values will not be sent to LaunchDarkly in analytics events and will not
    # appear on the LaunchDarkly dashboard.
    # @return [Boolean]
    # @see #private_attribute_names
    #
    attr_reader :all_attributes_private

    #
    # A list of user attribute names that should always be considered private. This means that the
    # attribute values will not be sent to LaunchDarkly in analytics events and will not appear on
    # the LaunchDarkly dashboard.
    #
    # You can also specify the same behavior for an individual flag evaluation by storing an array
    # of attribute names in the `:privateAttributeNames` property (note camelcase name) of the
    # user object.
    #
    # @return [Array<String>]
    # @see #all_attributes_private
    #
    attr_reader :private_attribute_names
    
    #
    # Whether to send events back to LaunchDarkly. This differs from {#offline?} in that it affects
    # only the sending of client-side events, not streaming or polling for events from the server.
    # @return [Boolean]
    #
    attr_reader :send_events

    #
    # The number of user keys that the event processor can remember at any one time. This reduces the
    # amount of duplicate user details sent in analytics events.
    # @return [Integer]
    # @see #user_keys_flush_interval
    #
    attr_reader :user_keys_capacity

    #
    # The interval in seconds at which the event processor will reset its set of known user keys.
    # @return [Float]
    # @see #user_keys_capacity
    #
    attr_reader :user_keys_flush_interval

    #
    # Whether to include full user details in every analytics event. By default, events will only
    # include the user key, except for one "index" event that provides the full details for the user.
    # The only reason to change this is if you are using the Analytics Data Stream.
    # @return [Boolean]
    #
    attr_reader :inline_users_in_events

    #
    # An object that is responsible for receiving feature flag data from LaunchDarkly. By default,
    # the client uses its standard polling or streaming implementation; this is customizable for
    # testing purposes.
    #
    # This may be set to either an object that conforms to {LaunchDarkly::Interfaces::DataSource},
    # or a lambda (or Proc) that takes two parameters-- SDK key and {Config}-- and returns such an
    # object.
    #
    # @return [LaunchDarkly::Interfaces::DataSource|lambda]
    # @see FileDataSource
    #
    attr_reader :data_source

    # @deprecated This is replaced by {#data_source}.
    attr_reader :update_processor
    
    # @deprecated This is replaced by {#data_source}.
    attr_reader :update_processor_factory

    #
    # Set to true to opt out of sending diagnostics data.
    #
    # Unless `diagnostic_opt_out` is set to true, the client will send some diagnostics data to the LaunchDarkly servers
    # in order to assist in the development of future SDK improvements. These diagnostics consist of an initial payload
    # containing some details of the SDK in use, the SDK's configuration, and the platform the SDK is being run on, as
    # well as periodic information on irregular occurrences such as dropped events.
    # @return [Boolean]
    #
    def diagnostic_opt_out?
      @diagnostic_opt_out
    end

    #
    # The interval at which periodic diagnostic data is sent, in seconds.
    #
    # The default is 900 (every 15 minutes) and the minimum value is 60 (every minute).
    # @return [Float]
    #
    attr_reader :diagnostic_recording_interval

    #
    # For use by wrapper libraries to set an identifying name for the wrapper being used.
    #
    # This will be sent in User-Agent headers during requests to the LaunchDarkly servers to allow recording
    # metrics on the usage of these wrapper libraries.
    # @return [String]
    #
    attr_reader :wrapper_name

    #
    # For use by wrapper libraries to report the version of the library in use.
    #
    # If `wrapper_name` is not set, this field will be ignored. Otherwise the version string will be included in
    # the User-Agent headers along with the `wrapper_name` during requests to the LaunchDarkly servers.
    # @return [String]
    #
    attr_reader :wrapper_version

    #
    # The factory used to construct sockets for HTTP operations. The factory must
    # provide the method `open(uri, timeout)`. The `open` method must return a
    # connected stream that implements the `IO` class, such as a `TCPSocket`.
    #
    # Defaults to nil.
    # @return [#open]
    #
    attr_reader :socket_factory

    #
    # The default LaunchDarkly client configuration. This configuration sets
    # reasonable defaults for most users.
    # @return [Config] The default LaunchDarkly configuration.
    #
    def self.default
      Config.new
    end

    #
    # The default value for {#capacity}.
    # @return [Integer] 10000
    #
    def self.default_capacity
      10000
    end

    #
    # The default value for {#base_uri}.
    # @return [String] "https://sdk.launchdarkly.com"
    #
    def self.default_base_uri
      "https://sdk.launchdarkly.com"
    end

    #
    # The default value for {#stream_uri}.
    # @return [String] "https://stream.launchdarkly.com"
    #
    def self.default_stream_uri
      "https://stream.launchdarkly.com"
    end

    #
    # The default value for {#events_uri}.
    # @return [String] "https://events.launchdarkly.com"
    #
    def self.default_events_uri
      "https://events.launchdarkly.com"
    end

    #
    # The default value for {#cache_store}.
    # @return [Object] the Rails cache if in Rails, or a simple in-memory implementation otherwise
    #
    def self.default_cache_store
      defined?(Rails) && Rails.respond_to?(:cache) ? Rails.cache : ThreadSafeMemoryStore.new
    end

    #
    # The default value for {#flush_interval}.
    # @return [Float] 10
    #
    def self.default_flush_interval
      10
    end

    #
    # The default value for {#read_timeout}.
    # @return [Float] 10
    #
    def self.default_read_timeout
      10
    end

    #
    # The default value for {#connect_timeout}.
    # @return [Float] 10
    #
    def self.default_connect_timeout
      2
    end

    #
    # The default value for {#logger}.
    # @return [Logger] the Rails logger if in Rails, or a default Logger at WARN level otherwise
    #
    def self.default_logger
      if defined?(Rails) && Rails.respond_to?(:logger)
        Rails.logger 
      else 
        log = ::Logger.new($stdout)
        log.level = ::Logger::WARN
        log
      end
    end

    #
    # The default value for {#stream?}.
    # @return [Boolean] true
    #
    def self.default_stream
      true
    end

    #
    # The default value for {#use_ldd?}.
    # @return [Boolean] false
    #
    def self.default_use_ldd
      false
    end

    #
    # The default value for {#feature_store}.
    # @return [LaunchDarkly::Interfaces::FeatureStore] an {InMemoryFeatureStore}
    #
    def self.default_feature_store
      InMemoryFeatureStore.new
    end

    #
    # The default value for {#offline?}.
    # @return [Boolean] false
    #
    def self.default_offline
      false
    end

    #
    # The default value for {#poll_interval}.
    # @return [Float] 30
    #
    def self.default_poll_interval
      30
    end

    #
    # The default value for {#send_events}.
    # @return [Boolean] true
    #
    def self.default_send_events
      true
    end

    #
    # The default value for {#user_keys_capacity}.
    # @return [Integer] 1000
    #
    def self.default_user_keys_capacity
      1000
    end

    #
    # The default value for {#user_keys_flush_interval}.
    # @return [Float] 300
    #
    def self.default_user_keys_flush_interval
      300
    end

    #
    # The default value for {#diagnostic_recording_interval}.
    # @return [Float] 900
    #
    def self.default_diagnostic_recording_interval
      900
    end

    #
    # The minimum value for {#diagnostic_recording_interval}.
    # @return [Float] 60
    #
    def self.minimum_diagnostic_recording_interval
      60
    end
  end
end
