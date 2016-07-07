require "digest/sha1"
require "logger"
require "benchmark"
require "waitutil"
require "json"

module LaunchDarkly
  #
  # A client for the LaunchDarkly API. Client instances are thread-safe. Users
  # should create a single client instance for the lifetime of the application.
  #
  #
  class LDClient
    include Settings
    include Evaluation
    #
    # Creates a new client instance that connects to LaunchDarkly. A custom
    # configuration parameter can also supplied to specify advanced options,
    # but for most use cases, the default configuration is appropriate.
    #
    #
    # @param api_key [String] the API key for your LaunchDarkly account
    # @param config [Config] an optional client configuration object
    #
    # @return [LDClient] The LaunchDarkly client instance
    def initialize(api_key, config = Config.default, wait_for_sec = 0)
      @api_key = api_key
      @config = config
      @store = config.feature_store
      requestor = Requestor.new(api_key, config)

      if !@config.offline?
        if @config.stream?
          @update_processor = StreamProcessor.new(api_key, config, requestor)
        else 
          @update_processor = PollingProcessor.new(config, requestor)
        end
        @update_processor.start
      end

      @event_processor = EventProcessor.new(api_key, config)

      if !@config.offline? && wait_for_sec > 0
        begin
          WaitUtil.wait_for_condition("LaunchDarkly client initialization", :timeout_sec => wait_for_sec, :delay_sec => 0.1) do
            @update_processor.initialized?
          end
        rescue WaitUtil::TimeoutError
          @config.logger.error("[LDClient] Timeout encountered waiting for LaunchDarkly client initialization")
        end
      end
    end

    def flush
      @event_processor.flush
    end

    #
    # Calculates the value of a feature flag for a given user. At a minimum,
    # the user hash should contain a +:key+ .
    #
    # @example Basic user hash
    #      {key: "user@example.com"}
    #
    # For authenticated users, the +:key+ should be the unique identifier for
    # your user. For anonymous users, the +:key+ should be a session identifier
    # or cookie. In either case, the only requirement is that the key
    # is unique to a user.
    #
    # You can also pass IP addresses and country codes in the user hash.
    #
    # @example More complete user hash
    #   {key: "user@example.com", ip: "127.0.0.1", country: "US"}
    #
    # Countries should be sent as ISO 3166-1 alpha-2 codes.
    #
    # The user hash can contain arbitrary custom attributes stored in a +:custom+ sub-hash:
    #
    # @example A user hash with custom attributes
    #   {key: "user@example.com", custom: {customer_rank: 1000, groups: ["google", "microsoft"]}}
    #
    # Attribute values in the custom hash can be integers, booleans, strings, or
    #   lists of integers, booleans, or strings.
    #
    # @param key [String] the unique feature key for the feature flag, as shown
    #   on the LaunchDarkly dashboard
    # @param user [Hash] a hash containing parameters for the end user requesting the flag
    # @param default=false [Boolean] the default value of the flag
    #
    # @return [Boolean] whether or not the flag should be enabled, or the
    #   default value if the flag is disabled on the LaunchDarkly control panel
    def toggle?(key, user, default = false)
      return default if @config.offline?

      unless user
        @config.logger.error("[LDClient] Must specify user")
        @event_processor.add_event(kind: "feature", key: key, value: default, default: default)        
        return default
      end

      if !@update_processor.initialized?
        @config.logger.error("[LDClient] Client has not finished initializing. Returning default value")
        @event_processor.add_event(kind: "feature", key: key, value: default, default: default)        
        return default
      end

      sanitize_user(user)
      feature = @store.get(key)

        begin
          res = evaluate(feature, user, @config.store)
          if !res[:events].nil?
            res[:events] do |event|
              @event_processor.add_event(event)
            end
          end
          if !res[:value].nil?
            @event_processor.add_event(kind: "feature", key: key, user: user, value: res[:value], default: default)
            return res[:value]
          else
            @config.logger.debug("[LDClient] Result value is null in toggle")
            @event_processor.add_event(kind: "feature", key: key, value: default, default: default)        
            return default            
          end
        rescue => exn
          @config.logger.warn("[LDClient] Error evaluating feature flag: #{exn.inspect}")
          @event_processor.add_event(kind: "feature", key: key, user: user, value: default, default: default)
          return default
        end
    end

    #
    # Registers the user
    #
    # @param [Hash] The user to register
    #
    def identify(user)
      sanitize_user(user)
      @event_processor.add_event(kind: "identify", key: user[:key], user: user)
    end

    #
    # Tracks that a user performed an event
    #
    # @param event_name [String] The name of the event
    # @param user [Hash] The user that performed the event. This should be the same user hash used in calls to {#toggle?}
    # @param data [Hash] A hash containing any additional data associated with the event
    #
    # @return [void]
    def track(event_name, user, data)
      sanitize_user(user)
      @event_processor.add_event(kind: "custom", key: event_name, user: user, data: data)
    end

    #
    # Returns all feature flag values for the given user
    #
    def all_flags(user)
      return Hash.new if @config.offline?

      features = @store.all

      Hash[features{|k,f| [k, evaluate(f, user, @config.store)[:value]] }]
    end

    def log_exception(caller, exn)
      error_traceback = "#{exn.inspect} #{exn}\n\t#{exn.backtrace.join("\n\t")}"
      error = "[LDClient] Unexpected exception in #{caller}: #{error_traceback}"
      @config.logger.error(error)
    end

    def sanitize_user(user)
      if user[:key]
        user[:key] = user[:key].to_s
      end
    end

    private :param_for_user, :match_target?, :match_user?, :match_variation?, :evaluate,
            :log_exception, :sanitize_user, :find_weight_match, :find_target_match, :find_user_match
  end
end
