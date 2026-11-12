require "logger"
require "ldclient-rb/impl/data_system/http_config_options"
require "ldclient-rb/impl/data_system/polling"
require "ldclient-rb/impl/data_system/streaming"

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
    # @option opts [String] :events_uri ("https://events.launchdarkly.com") See {#events_uri}.
    # @option opts [Integer] :capacity (10000) See {#capacity}.
    # @option opts [Float] :flush_interval (30) See {#flush_interval}.
    # @option opts [Float] :read_timeout (10) See {#read_timeout}.
    # @option opts [Float] :connect_timeout (2) See {#connect_timeout}.
    # @option opts [Boolean] :offline (false) See {#offline?}.
    # @option opts [Boolean] all_attributes_private (false) See {#all_attributes_private}.
    # @option opts [Enumerable<String>] :private_attributes See {#private_attributes}.
    # @option opts [Boolean] :send_events (true) See {#send_events}.
    # @option opts [Integer] :context_keys_capacity (1000) See {#context_keys_capacity}.
    # @option opts [Float] :context_keys_flush_interval (300) See {#context_keys_flush_interval}.
    # @option opts [Boolean] :diagnostic_opt_out (false) See {#diagnostic_opt_out?}.
    # @option opts [Float] :diagnostic_recording_interval (900) See {#diagnostic_recording_interval}.
    # @option opts [String] :wrapper_name See {#wrapper_name}.
    # @option opts [String] :wrapper_version See {#wrapper_version}.
    # @option opts [#open] :socket_factory See {#socket_factory}.
    # @option opts [BigSegmentsConfig] :big_segments See {#big_segments}.
    # @option opts [Hash] :application See {#application}
    # @option opts [Boolean] :omit_anonymous_contexts See {#omit_anonymous_contexts}
    # @option opts [DataSystemConfig] :data_system See {#data_system}
    # @option hooks [Array<Interfaces::Hooks::Hook]
    # @option plugins [Array<Interfaces::Plugins::Plugin]
    #
    def initialize(opts = {})
      @events_uri = (opts[:events_uri] || Config.default_events_uri).chomp("/")
      @capacity = opts[:capacity] || Config.default_capacity
      @logger = opts[:logger] || Config.default_logger
      @flush_interval = opts[:flush_interval] || Config.default_flush_interval
      @connect_timeout = opts[:connect_timeout] || Config.default_connect_timeout
      @read_timeout = opts[:read_timeout] || Config.default_read_timeout
      @offline = opts.has_key?(:offline) ? opts[:offline] : Config.default_offline
      @all_attributes_private = opts[:all_attributes_private] || false
      @private_attributes = Set.new(opts[:private_attributes] || []).freeze
      @send_events = opts.has_key?(:send_events) ? opts[:send_events] : Config.default_send_events
      @compress_events = opts.has_key?(:compress_events) ? opts[:compress_events] : Config.default_compress_events
      @context_keys_capacity = opts[:context_keys_capacity] || Config.default_context_keys_capacity
      @context_keys_flush_interval = opts[:context_keys_flush_interval] || Config.default_context_keys_flush_interval
      @diagnostic_opt_out = opts.has_key?(:diagnostic_opt_out) && opts[:diagnostic_opt_out]
      @diagnostic_recording_interval = opts.has_key?(:diagnostic_recording_interval) && opts[:diagnostic_recording_interval] > Config.minimum_diagnostic_recording_interval ?
        opts[:diagnostic_recording_interval] : Config.default_diagnostic_recording_interval
      @wrapper_name = opts[:wrapper_name]
      @wrapper_version = opts[:wrapper_version]
      @socket_factory = opts[:socket_factory]
      @big_segments = opts[:big_segments] || BigSegmentsConfig.new(store: nil)
      @application = LaunchDarkly::Impl::Util.validate_application_info(opts[:application] || {}, @logger)
      @hooks = (opts[:hooks] || []).keep_if { |hook| hook.is_a? Interfaces::Hooks::Hook }
      @plugins = (opts[:plugins] || []).keep_if { |plugin| plugin.is_a? Interfaces::Plugins::Plugin }
      @omit_anonymous_contexts = opts.has_key?(:omit_anonymous_contexts) && opts[:omit_anonymous_contexts]
      @data_system = opts[:data_system]
      @instance_id = nil
    end


    #
    # Returns the unique identifier for this instance of the SDK.
    #
    # This property should only be set by the SDK. Long term access of this
    # property is not supported; it is temporarily being exposed to maintain
    # backwards compatibility while the SDK structure is updated.
    #
    # @api private
    #
    attr_accessor :instance_id

    #
    # The base URL for the LaunchDarkly events server. This is configurable mainly for testing
    # purposes; most users should use the default value.
    # @return [String]
    #
    attr_reader :events_uri

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
    # True if all context attributes (other than the key) should be considered private. This means
    # that the attribute values will not be sent to LaunchDarkly in analytics events and will not
    # appear on the LaunchDarkly dashboard.
    # @return [Boolean]
    # @see #private_attributes
    #
    attr_reader :all_attributes_private

    #
    # A set of context attribute names that should always be considered private. This means that the
    # attribute values will not be sent to LaunchDarkly in analytics events and will not appear on
    # the LaunchDarkly dashboard.
    #
    # You can also specify the same behavior for an individual flag evaluation
    # by providing the context object with a list of private attributes.
    #
    # Each entry is an attribute reference. A reference addresses attributes by
    # symbol name, so it cannot make an attribute private if that attribute was
    # given a string name. Refer to {LDContext} for the symbol requirement.
    #
    # @see https://docs.launchdarkly.com/sdk/features/user-context-config#using-private-attributes
    #
    # @return [Set<String>]
    # @see #all_attributes_private
    #
    attr_reader :private_attributes

    #
    # Whether to send events back to LaunchDarkly. This differs from {#offline?} in that it affects
    # only the sending of client-side events, not streaming or polling for events from the server.
    # @return [Boolean]
    #
    attr_reader :send_events

    #
    # Should the event payload sent to LaunchDarkly use gzip compression. The default is true.
    #
    # Relay Proxy versions before 8.9 cannot accept compressed events. If you send events through the Relay Proxy,
    # set this to false. Older Relay Proxy versions cannot decode compressed payloads. Newer versions decode and
    # compress the payloads again, which adds CPU overhead.
    #
    # @return [Boolean]
    #
    attr_reader :compress_events

    #
    # The number of context keys that the event processor can remember at any one time. This reduces the
    # amount of duplicate context details sent in analytics events.
    # @return [Integer]
    # @see #context_keys_flush_interval
    #
    attr_reader :context_keys_capacity

    #
    # The interval in seconds at which the event processor will reset its set of known context keys.
    # @return [Float]
    # @see #context_keys_capacity
    #
    attr_reader :context_keys_flush_interval

    #
    # Configuration options related to Big Segments.
    #
    # Big Segments are a specific type of segments. For more information, read the LaunchDarkly
    # documentation: https://docs.launchdarkly.com/home/users/big-segments
    #
    # @return [BigSegmentsConfig]
    #
    attr_reader :big_segments

    #
    # An object that allows configuration of application metadata.
    #
    # Application metadata may be used in LaunchDarkly analytics or other product features, but does not affect feature flag evaluations.
    #
    # If you want to set non-default values for any of these fields, provide the appropriately configured hash to the {Config} object.
    #
    # @example Configuring application information
    #   opts[:application] = {
    #     id: "MY APPLICATION ID",
    #     version: "MY APPLICATION VERSION"
    #   }
    #   config = LDConfig.new(opts)
    #
    # @return [Hash]
    #
    attr_reader :application

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
    # Returns a copy of this configuration with different wrapper information.
    #
    # This is intended for use by wrapper libraries, such as the LaunchDarkly OpenFeature provider, which need to
    # identify themselves rather than the application which created the configuration.
    #
    # The copy is shallow: it shares the objects the original configuration references, such as the feature store,
    # the logger, and the socket factory. Mutating one of those objects affects both configurations.
    #
    # @param wrapper_name [String, nil] see {#wrapper_name}
    # @param wrapper_version [String, nil] see {#wrapper_version}
    #
    # @return [LaunchDarkly::Config]
    #
    def with_wrapper_information(wrapper_name, wrapper_version = nil)
      updated = dup
      updated.wrapper_name = wrapper_name
      updated.wrapper_version = wrapper_version

      updated
    end

    protected attr_writer :wrapper_name, :wrapper_version

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
    # Initial set of hooks for the client.
    #
    # Hooks provide entrypoints which allow for observation of SDK functions.
    #
    # LaunchDarkly provides integration packages, and most applications will not
    # need to implement their own hooks. Refer to the `launchdarkly-server-sdk-otel` gem
    # for instrumentation.
    #
    attr_reader :hooks

    #
    # Initial set of plugins for the client.
    #
    # Plugins provide an interface which allows for initialization, access to credentials, and hook registration
    # in a single interface.
    #
    attr_reader :plugins

    #
    # Sets whether anonymous contexts should be omitted from index and identify events.
    #
    # The default value is false. Anonymous contexts will be included in index and identify events.
    # @return [Boolean]
    #
    attr_reader :omit_anonymous_contexts

    #
    # Configuration for the data system, which controls how the SDK gets
    # flag and segment data. If this is nil, the client uses
    # {LaunchDarkly::DataSystem.default}.
    #
    # @return [DataSystemConfig, nil]
    #
    attr_reader :data_system

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
    # The default value for {#events_uri}.
    # @return [String] "https://events.launchdarkly.com"
    #
    def self.default_events_uri
      "https://events.launchdarkly.com"
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
      Impl::DataSystem::HttpConfigOptions::DEFAULT_READ_TIMEOUT
    end

    #
    # The default value for {#connect_timeout}.
    # @return [Float] 2
    #
    def self.default_connect_timeout
      Impl::DataSystem::HttpConfigOptions::DEFAULT_CONNECT_TIMEOUT
    end

    #
    # The default value for {#logger}.
    # @return [Logger] the Rails logger if in Rails, or a default Logger at WARN level otherwise
    #
    def self.default_logger
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger
      else
        log = ::Logger.new($stdout)
        log.level = ::Logger::WARN
        log
      end
    end

    #
    # The default value for {#offline?}.
    # @return [Boolean] false
    #
    def self.default_offline
      false
    end

    #
    # The default value for {#send_events}.
    # @return [Boolean] true
    #
    def self.default_send_events
      true
    end

    #
    # The default value for {#compress_events}.
    # @return [Boolean] true
    #
    def self.default_compress_events
      true
    end

    #
    # The default value for {#context_keys_capacity}.
    # @return [Integer] 1000
    #
    def self.default_context_keys_capacity
      1000
    end

    #
    # The default value for {#context_keys_flush_interval}.
    # @return [Float] 300
    #
    def self.default_context_keys_flush_interval
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

  #
  # Configuration options related to Big Segments.
  #
  # Big Segments are a specific type of segments. For more information, read the LaunchDarkly
  # documentation: https://docs.launchdarkly.com/home/users/big-segments
  #
  # If your application uses Big Segments, you will need to create a `BigSegmentsConfig` that at a
  # minimum specifies what database integration to use, and then pass the `BigSegmentsConfig`
  # object as the `big_segments` parameter when creating a {Config}.
  #
  # @example Configuring Big Segments with Redis
  #     store = LaunchDarkly::Integrations::Redis::new_big_segments_store(redis_url: "redis://my-server")
  #     config = LaunchDarkly::Config.new(big_segments:
  #       LaunchDarkly::BigSegmentsConfig.new(store: store))
  #     client = LaunchDarkly::LDClient.new(my_sdk_key, config)
  #
  class BigSegmentsConfig
    DEFAULT_CONTEXT_CACHE_SIZE = 1000
    DEFAULT_CONTEXT_CACHE_TIME = 5
    DEFAULT_STATUS_POLL_INTERVAL = 5
    DEFAULT_STALE_AFTER = 2 * 60

    #
    # Constructor for setting Big Segments options.
    #
    # @param store [LaunchDarkly::Interfaces::BigSegmentStore] the data store implementation
    # @param context_cache_size [Integer] See {#context_cache_size}.
    # @param context_cache_time [Float] See {#context_cache_time}.
    # @param status_poll_interval [Float] See {#status_poll_interval}.
    # @param stale_after [Float] See {#stale_after}.
    #
    def initialize(store:, context_cache_size: nil, context_cache_time: nil, status_poll_interval: nil, stale_after: nil)
      @store = store
      @context_cache_size = context_cache_size.nil? ? DEFAULT_CONTEXT_CACHE_SIZE : context_cache_size
      @context_cache_time = context_cache_time.nil? ? DEFAULT_CONTEXT_CACHE_TIME : context_cache_time
      @status_poll_interval = status_poll_interval.nil? ? DEFAULT_STATUS_POLL_INTERVAL : status_poll_interval
      @stale_after = stale_after.nil? ? DEFAULT_STALE_AFTER : stale_after
    end

    # The implementation of {LaunchDarkly::Interfaces::BigSegmentStore} that will be used to
    # query the Big Segments database.
    # @return [LaunchDarkly::Interfaces::BigSegmentStore]
    attr_reader :store

    # The maximum number of contexts whose Big Segment state will be cached by the SDK at any given time.
    # @return [Integer]
    attr_reader :context_cache_size

    # The maximum length of time (in seconds) that the Big Segment state for a context will be cached
    # by the SDK.
    # @return [Float]
    attr_reader :context_cache_time

    # The interval (in seconds) at which the SDK will poll the Big Segment store to make sure it is
    # available and to determine how long ago it was updated.
    # @return [Float]
    attr_reader :status_poll_interval

    # The maximum length of time between updates of the Big Segments data before the data is
    # considered out of date.
    # @return [Float]
    attr_reader :stale_after
  end

  #
  # Configuration for LaunchDarkly's data acquisition strategy.
  #
  class DataSystemConfig
    #
    # @param initializers [Array<#build(String, Config)>, nil] The (optional) array of builders
    # @param synchronizers [Array<#build(String, Config)>, nil] The (optional) array of synchronizer builders
    # @param data_store_mode [Symbol] The (optional) data store mode
    # @param data_store [LaunchDarkly::Interfaces::FeatureStore, nil] The (optional) data store
    # @param fdv1_fallback_synchronizer [#build(String, Config), nil]
    #   The (optional) builder for FDv1-compatible fallback synchronizer
    #
    def initialize(initializers: nil, synchronizers: nil,
                   data_store_mode: LaunchDarkly::Interfaces::DataSystem::DataStoreMode::READ_ONLY, data_store: nil, fdv1_fallback_synchronizer: nil)
      @initializers = initializers
      @synchronizers = synchronizers
      @data_store_mode = data_store_mode
      @data_store = data_store
      @fdv1_fallback_synchronizer = fdv1_fallback_synchronizer
    end

    # The initializer builders for the data system. Each builder responds to build(sdk_key, config) and returns an Initializer.
    # @return [Array<#build(String, Config)>, nil]
    attr_reader :initializers

    # The synchronizer builders for the data system. Each builder responds to build(sdk_key, config) and returns a Synchronizer.
    # @return [Array<#build(String, Config)>, nil]
    attr_reader :synchronizers

    # The data store mode.
    # @return [Symbol]
    attr_reader :data_store_mode

    # The data store.
    # @return [LaunchDarkly::Interfaces::FeatureStore, nil]
    attr_reader :data_store

    # The FDv1-compatible fallback synchronizer builder. Responds to build(sdk_key, config) and returns a Synchronizer.
    # @return [#build(String, Config), nil]
    attr_reader :fdv1_fallback_synchronizer
  end
end
