require "digest/sha1"
require "logger"
require "benchmark"
require "waitutil"
require "json"
require "openssl"

module LaunchDarkly
  #
  # A client for LaunchDarkly. Client instances are thread-safe. Users
  # should create a single client instance for the lifetime of the application.
  #
  #
  class LDClient
    include Evaluation
    #
    # Creates a new client instance that connects to LaunchDarkly. A custom
    # configuration parameter can also supplied to specify advanced options,
    # but for most use cases, the default configuration is appropriate.
    #
    #
    # @param sdk_key [String] the SDK key for your LaunchDarkly account
    # @param config [Config] an optional client configuration object
    #
    # @return [LDClient] The LaunchDarkly client instance
    def initialize(sdk_key, config = Config.default, wait_for_sec = 5)
      @sdk_key = sdk_key
      @config = config
      @store = config.feature_store

      if @config.offline? || !@config.send_events
        @event_processor = NullEventProcessor.new
      else
        @event_processor = EventProcessor.new(sdk_key, config)
      end

      if @config.use_ldd?
        @config.logger.info { "[LDClient] Started LaunchDarkly Client in LDD mode" }
        return  # requestor and update processor are not used in this mode
      end

      requestor = Requestor.new(sdk_key, config)

      if !@config.offline?
        if @config.update_processor.nil?
          if @config.stream?
            @update_processor = StreamProcessor.new(sdk_key, config, requestor)
          else
            @config.logger.info { "Disabling streaming API" }
            @config.logger.warn { "You should only disable the streaming API if instructed to do so by LaunchDarkly support" }
            @update_processor = PollingProcessor.new(config, requestor)
          end
        else
          @update_processor = @config.update_processor
        end
        @update_processor.start
      end

      if !@config.offline? && wait_for_sec > 0
        begin
          WaitUtil.wait_for_condition("LaunchDarkly client initialization", timeout_sec: wait_for_sec, delay_sec: 0.1) do
            initialized?
          end
        rescue WaitUtil::TimeoutError
          @config.logger.error { "[LDClient] Timeout encountered waiting for LaunchDarkly client initialization" }
        end
      end
    end

    def flush
      @event_processor.flush
    end

    def toggle?(key, user, default = False)
      @config.logger.warn { "[LDClient] toggle? is deprecated. Use variation instead" }
      variation(key, user, default)
    end

    def secure_mode_hash(user)
      OpenSSL::HMAC.hexdigest("sha256", @sdk_key, user[:key].to_s)
    end

    # Returns whether the client has been initialized and is ready to serve feature flag requests
    # @return [Boolean] true if the client has been initialized
    def initialized?
      @config.offline? || @config.use_ldd? || @update_processor.initialized?
    end

    #
    # Determines the variation of a feature flag to present to a user. At a minimum,
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
    # @param default=false the default value of the flag
    #
    # @return the variation to show the user, or the
    #   default value if there's an an error
    def variation(key, user, default)
      return default if @config.offline?

      unless user
        @config.logger.error { "[LDClient] Must specify user" }
        @event_processor.add_event(kind: "feature", key: key, value: default, default: default, user: user)
        return default
      end

      if !initialized?
        if @store.initialized?
          @config.logger.warn { "[LDClient] Client has not finished initializing; using last known values from feature store" }
        else
          @config.logger.error { "[LDClient] Client has not finished initializing; feature store unavailable, returning default value" }
          @event_processor.add_event(kind: "feature", key: key, value: default, default: default, user: user)
          return default
        end
      end

      sanitize_user(user)
      feature = @store.get(FEATURES, key)

      if feature.nil?
        @config.logger.info { "[LDClient] Unknown feature flag #{key}. Returning default value" }
        @event_processor.add_event(kind: "feature", key: key, value: default, default: default, user: user)
        return default
      end

      begin
        res = evaluate(feature, user, @store, @config.logger)
        if !res[:events].nil?
          res[:events].each do |event|
            @event_processor.add_event(event)
          end
        end
        value = res[:value]
        if value.nil?
          @config.logger.debug { "[LDClient] Result value is null in toggle" }
          value = default
        end
        @event_processor.add_event(
          kind: "feature",
          key: key,
          user: user,
          variation: res[:variation],
          value: value,
          default: default,
          version: feature[:version],
          trackEvents: feature[:trackEvents],
          debugEventsUntilDate: feature[:debugEventsUntilDate]
        )
        return value
      rescue => exn
        @config.logger.warn { "[LDClient] Error evaluating feature flag: #{exn.inspect}. \nTrace: #{exn.backtrace}" }
        @event_processor.add_event(
          kind: "feature",
          key: key,
          user: user,
          value: default,
          default: default,
          version: feature[:version],
          trackEvents: feature[:trackEvents],
          debugEventsUntilDate: feature[:debugEventsUntilDate]
        )
        return default
      end
    end

    #
    # Registers the user
    #
    # @param [Hash] The user to register
    #
    # @return [void]
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
      sanitize_user(user)
      return Hash.new if @config.offline?

      unless user
        @config.logger.error { "[LDClient] Must specify user in all_flags" }
        return Hash.new
      end

      begin
        features = @store.all(FEATURES)

        # TODO rescue if necessary
        Hash[features.map{ |k, f| [k, evaluate(f, user, @store, @config.logger)[:value]] }]
      rescue => exn
        @config.logger.warn { "[LDClient] Error evaluating all flags: #{exn.inspect}. \nTrace: #{exn.backtrace}" }
        return Hash.new
      end
    end

    #
    # Releases all network connections and other resources held by the client, making it no longer usable
    #
    # @return [void]
    def close
      @config.logger.info { "[LDClient] Closing LaunchDarkly client..." }
      if not @config.offline?
        @update_processor.stop
      end
      @event_processor.stop
      @store.stop
    end

    def log_exception(caller, exn)
      error_traceback = "#{exn.inspect} #{exn}\n\t#{exn.backtrace.join("\n\t")}"
      error = "[LDClient] Unexpected exception in #{caller}: #{error_traceback}"
      @config.logger.error { error }
    end

    def sanitize_user(user)
      if user[:key]
        user[:key] = user[:key].to_s
      end
    end

    private :evaluate, :log_exception, :sanitize_user
  end
end
