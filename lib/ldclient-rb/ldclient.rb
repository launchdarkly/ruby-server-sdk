require "concurrent/atomics"
require "digest/sha1"
require "logger"
require "benchmark"
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

      if @config.offline?
        @update_processor = NullUpdateProcessor.new
      else
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
      end

      ready = @update_processor.start
      if wait_for_sec > 0
        ok = ready.wait(wait_for_sec)
        if !ok
          @config.logger.error { "[LDClient] Timeout encountered waiting for LaunchDarkly client initialization" }
        elsif !@update_processor.initialized?
          @config.logger.error { "[LDClient] LaunchDarkly client initialization failed" }
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
    # @param default the default value of the flag
    #
    # @return the variation to show the user, or the
    #   default value if there's an an error
    def variation(key, user, default)
      evaluate_internal(key, user, default, false).value
    end

    #
    # Determines the variation of a feature flag for a user, like `variation`, but also
    # provides additional information about how this value was calculated.
    #
    # The return value of `variation_detail` is an `EvaluationDetail` object, which has
    # three properties:
    #
    # `value`: the value that was calculated for this user (same as the return value
    # of `variation`)
    #
    # `variation_index`: the positional index of this value in the flag, e.g. 0 for the
    # first variation - or `nil` if the default value was returned
    #
    # `reason`: a hash describing the main reason why this value was selected. Its `:kind`
    # property will be one of the following:
    #
    # * `'OFF'`: the flag was off and therefore returned its configured off value
    # * `'FALLTHROUGH'`: the flag was on but the user did not match any targets or rules
    # * `'TARGET_MATCH'`: the user key was specifically targeted for this flag
    # * `'RULE_MATCH'`: the user matched one of the flag's rules; the `:ruleIndex` and
    # `:ruleId` properties indicate the positional index and unique identifier of the rule
    # * `'PREREQUISITE_FAILED`': the flag was considered off because it had at least one
    # prerequisite flag that either was off or did not return the desired variation; the
    # `:prerequisiteKey` property indicates the key of the prerequisite that failed
    # * `'ERROR'`: the flag could not be evaluated, e.g. because it does not exist or due
    # to an unexpected error, and therefore returned the default value; the `:errorKind`
    # property describes the nature of the error, such as `'FLAG_NOT_FOUND'`
    #
    # The `reason` will also be included in analytics events, if you are capturing
    # detailed event data for this flag.
    #
    # @param key [String] the unique feature key for the feature flag, as shown
    #   on the LaunchDarkly dashboard
    # @param user [Hash] a hash containing parameters for the end user requesting the flag
    # @param default the default value of the flag
    #
    # @return an `EvaluationDetail` object describing the result
    #
    def variation_detail(key, user, default)
      evaluate_internal(key, user, default, true)
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
    # Returns all feature flag values for the given user. This method is deprecated - please use
    # {#all_flags_state} instead. Current versions of the client-side SDK will not generate analytics
    # events correctly if you pass the result of all_flags.
    #
    # @param user [Hash] The end user requesting the feature flags
    # @return [Hash] a hash of feature flag keys to values
    #
    def all_flags(user)
      all_flags_state(user).values_map
    end

    #
    # Returns a FeatureFlagsState object that encapsulates the state of all feature flags for a given user,
    # including the flag values and also metadata that can be used on the front end. This method does not
    # send analytics events back to LaunchDarkly.
    #
    # @param user [Hash] The end user requesting the feature flags
    # @param options={} [Hash] Optional parameters to control how the state is generated
    # @option options [Boolean] :client_side_only (false) True if only flags marked for use with the
    #   client-side SDK should be included in the state. By default, all flags are included.
    # @option options [Boolean] :with_reasons (false) True if evaluation reasons should be included
    #   in the state (see `variation_detail`). By default, they are not included.
    # @return [FeatureFlagsState] a FeatureFlagsState object which can be serialized to JSON
    #
    def all_flags_state(user, options={})
      return FeatureFlagsState.new(false) if @config.offline?

      unless user && !user[:key].nil?
        @config.logger.error { "[LDClient] User and user key must be specified in all_flags_state" }
        return FeatureFlagsState.new(false)
      end

      sanitize_user(user)

      begin
        features = @store.all(FEATURES)
      rescue => exn
        Util.log_exception(@config.logger, "Unable to read flags for all_flags_state", exn)
        return FeatureFlagsState.new(false)
      end

      state = FeatureFlagsState.new(true)
      client_only = options[:client_side_only] || false
      with_reasons = options[:with_reasons] || false
      features.each do |k, f|
        if client_only && !f[:clientSide]
          next
        end
        begin
          result = evaluate(f, user, @store, @config.logger)
          state.add_flag(f, result.detail.value, result.detail.variation_index, with_reasons ? result.detail.reason : nil)
        rescue => exn
          Util.log_exception(@config.logger, "Error evaluating flag \"#{k}\" in all_flags_state", exn)
          state.add_flag(f, nil, nil, with_reasons ? { kind: 'ERROR', errorKind: 'EXCEPTION' } : nil)
        end
      end

      state
    end

    #
    # Releases all network connections and other resources held by the client, making it no longer usable
    #
    # @return [void]
    def close
      @config.logger.info { "[LDClient] Closing LaunchDarkly client..." }
      @update_processor.stop
      @event_processor.stop
      @store.stop
    end

    private

    # @return [EvaluationDetail]
    def evaluate_internal(key, user, default, include_reasons_in_events)
      if @config.offline?
        return error_result('CLIENT_NOT_READY', default)
      end

      if !initialized?
        if @store.initialized?
          @config.logger.warn { "[LDClient] Client has not finished initializing; using last known values from feature store" }
        else
          @config.logger.error { "[LDClient] Client has not finished initializing; feature store unavailable, returning default value" }
          @event_processor.add_event(kind: "feature", key: key, value: default, default: default, user: user)
          return error_result('CLIENT_NOT_READY', default)
        end
      end

      sanitize_user(user) if !user.nil?
      feature = @store.get(FEATURES, key)

      if feature.nil?
        @config.logger.info { "[LDClient] Unknown feature flag \"#{key}\". Returning default value" }
        detail = error_result('FLAG_NOT_FOUND', default)
        @event_processor.add_event(kind: "feature", key: key, value: default, default: default, user: user,
          reason: include_reasons_in_events ? detail.reason : nil)
        return detail
      end

      unless user
        @config.logger.error { "[LDClient] Must specify user" }
        detail = error_result('USER_NOT_SPECIFIED', default)
        @event_processor.add_event(make_feature_event(feature, user, detail, default, include_reasons_in_events))
        return detail
      end

      begin
        res = evaluate(feature, user, @store, @config.logger)
        if !res.events.nil?
          res.events.each do |event|
            @event_processor.add_event(event)
          end
        end
        detail = res.detail
        if detail.default_value?
          detail = EvaluationDetail.new(default, nil, detail.reason)
        end
        @event_processor.add_event(make_feature_event(feature, user, detail, default, include_reasons_in_events))
        return detail
      rescue => exn
        Util.log_exception(@config.logger, "Error evaluating feature flag \"#{key}\"", exn)
        detail = error_result('EXCEPTION', default)
        @event_processor.add_event(make_feature_event(feature, user, detail, default, include_reasons_in_events))
        return detail
      end
    end

    def sanitize_user(user)
      if user[:key]
        user[:key] = user[:key].to_s
      end
    end

    def make_feature_event(flag, user, detail, default, with_reasons)
      {
        kind: "feature",
        key: flag[:key],
        user: user,
        variation: detail.variation_index,
        value: detail.value,
        default: default,
        version: flag[:version],
        trackEvents: flag[:trackEvents],
        debugEventsUntilDate: flag[:debugEventsUntilDate],
        reason: with_reasons ? detail.reason : nil
      }
    end
  end

  #
  # Used internally when the client is offline.
  #
  class NullUpdateProcessor
    def start
      e = Concurrent::Event.new
      e.set
      e
    end

    def initialized?
      true
    end

    def stop
    end
  end
end
