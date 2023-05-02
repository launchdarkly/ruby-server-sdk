require "ldclient-rb/impl/big_segments"
require "ldclient-rb/impl/broadcaster"
require "ldclient-rb/impl/data_source"
require "ldclient-rb/impl/data_store"
require "ldclient-rb/impl/diagnostic_events"
require "ldclient-rb/impl/evaluator"
require "ldclient-rb/impl/flag_tracker"
require "ldclient-rb/impl/store_client_wrapper"
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
  class LDClient
    include Impl
    #
    # Creates a new client instance that connects to LaunchDarkly. A custom
    # configuration parameter can also supplied to specify advanced options,
    # but for most use cases, the default configuration is appropriate.
    #
    # The client will immediately attempt to connect to LaunchDarkly and retrieve
    # your feature flag data. If it cannot successfully do so within the time limit
    # specified by `wait_for_sec`, the constructor will return a client that is in
    # an uninitialized state. See {#initialized?} for more details.
    #
    # @param sdk_key [String] the SDK key for your LaunchDarkly account
    # @param config [Config] an optional client configuration object
    # @param wait_for_sec [Float] maximum time (in seconds) to wait for initialization
    #
    # @return [LDClient] The LaunchDarkly client instance
    #
    def initialize(sdk_key, config = Config.default, wait_for_sec = 5)
      # Note that sdk_key is normally a required parameter, and a nil value would cause the SDK to
      # fail in most configurations. However, there are some configurations where it would be OK
      # (offline = true, *or* we are using LDD mode or the file data source and events are disabled
      # so we're not connecting to any LD services) so rather than try to check for all of those
      # up front, we will let the constructors for the data source implementations implement this
      # fail-fast as appropriate, and just check here for the part regarding events.
      if !config.offline? && config.send_events
        raise ArgumentError, "sdk_key must not be nil" if sdk_key.nil?
      end

      @sdk_key = sdk_key

      @shared_executor = Concurrent::SingleThreadExecutor.new

      data_store_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, config.logger)
      store_sink = LaunchDarkly::Impl::DataStore::UpdateSink.new(data_store_broadcaster)

      # We need to wrap the feature store object with a FeatureStoreClientWrapper in order to add
      # some necessary logic around updates. Unfortunately, we have code elsewhere that accesses
      # the feature store through the Config object, so we need to make a new Config that uses
      # the wrapped store.
      @store = Impl::FeatureStoreClientWrapper.new(config.feature_store, store_sink, config.logger)
      updated_config = config.clone
      updated_config.instance_variable_set(:@feature_store, @store)
      @config = updated_config

      @data_store_status_provider = LaunchDarkly::Impl::DataStore::StatusProvider.new(@store, store_sink)

      @big_segment_store_manager = Impl::BigSegmentStoreManager.new(config.big_segments, @config.logger)
      @big_segment_store_status_provider = @big_segment_store_manager.status_provider

      get_flag = lambda { |key| @store.get(FEATURES, key) }
      get_segment = lambda { |key| @store.get(SEGMENTS, key) }
      get_big_segments_membership = lambda { |key| @big_segment_store_manager.get_context_membership(key) }
      @evaluator = LaunchDarkly::Impl::Evaluator.new(get_flag, get_segment, get_big_segments_membership, @config.logger)

      if !@config.offline? && @config.send_events && !@config.diagnostic_opt_out?
        diagnostic_accumulator = Impl::DiagnosticAccumulator.new(Impl::DiagnosticAccumulator.create_diagnostic_id(sdk_key))
      else
        diagnostic_accumulator = nil
      end

      if @config.offline? || !@config.send_events
        @event_processor = NullEventProcessor.new
      else
        @event_processor = EventProcessor.new(sdk_key, config, nil, diagnostic_accumulator)
      end

      if @config.use_ldd?
        @config.logger.info { "[LDClient] Started LaunchDarkly Client in LDD mode" }
        return  # requestor and update processor are not used in this mode
      end

      flag_tracker_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, @config.logger)
      @flag_tracker = LaunchDarkly::Impl::FlagTracker.new(flag_tracker_broadcaster, lambda { |key, context| variation(key, context, nil) })

      data_source_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, @config.logger)

      # Make the update sink available on the config so that our data source factory can access the sink with a shared executor.
      @config.data_source_update_sink = LaunchDarkly::Impl::DataSource::UpdateSink.new(@store, data_source_broadcaster, flag_tracker_broadcaster)

      @data_source_status_provider = LaunchDarkly::Impl::DataSource::StatusProvider.new(data_source_broadcaster, @config.data_source_update_sink)

      data_source_or_factory = @config.data_source || self.method(:create_default_data_source)
      if data_source_or_factory.respond_to? :call
        # Currently, data source factories take two parameters unless they need to be aware of diagnostic_accumulator, in
        # which case they take three parameters. This will be changed in the future to use a less awkware mechanism.
        if data_source_or_factory.arity == 3
          @data_source = data_source_or_factory.call(sdk_key, @config, diagnostic_accumulator)
        else
          @data_source = data_source_or_factory.call(sdk_key, @config)
        end
      else
        @data_source = data_source_or_factory
      end

      ready = @data_source.start
      if wait_for_sec > 0
        ok = ready.wait(wait_for_sec)
        if !ok
          @config.logger.error { "[LDClient] Timeout encountered waiting for LaunchDarkly client initialization" }
        elsif !@data_source.initialized?
          @config.logger.error { "[LDClient] LaunchDarkly client initialization failed" }
        end
      end
    end

    #
    # Tells the client that all pending analytics events should be delivered as soon as possible.
    #
    # When the LaunchDarkly client generates analytics events (from {#variation}, {#variation_detail},
    # {#identify}, or {#track}), they are queued on a worker thread. The event thread normally
    # sends all queued events to LaunchDarkly at regular intervals, controlled by the
    # {Config#flush_interval} option. Calling `flush` triggers a send without waiting for the
    # next interval.
    #
    # Flushing is asynchronous, so this method will return before it is complete. However, if you
    # call {#close}, events are guaranteed to be sent before that method returns.
    #
    def flush
      @event_processor.flush
    end

    #
    # Creates a hash string that can be used by the JavaScript SDK to identify a context.
    # For more information, see [Secure mode](https://docs.launchdarkly.com/sdk/features/secure-mode#ruby).
    #
    # @param context [Hash, LDContext]
    # @return [String, nil] a hash string or nil if the provided context was invalid
    #
    def secure_mode_hash(context)
      context = Impl::Context::make_context(context)
      unless context.valid?
        @config.logger.warn("secure_mode_hash called with invalid context: #{context.error}")
        return nil
      end

      OpenSSL::HMAC.hexdigest("sha256", @sdk_key, context.fully_qualified_key)
    end

    #
    # Returns whether the client has been initialized and is ready to serve feature flag requests.
    #
    # If this returns false, it means that the client did not succeed in connecting to
    # LaunchDarkly within the time limit that you specified in the constructor. It could
    # still succeed in connecting at a later time (on another thread), or it could have
    # given up permanently (for instance, if your SDK key is invalid). In the meantime,
    # any call to {#variation} or {#variation_detail} will behave as follows:
    #
    # 1. It will check whether the feature store already contains data (that is, you
    # are using a database-backed store and it was populated by a previous run of this
    # application). If so, it will use the last known feature flag data.
    #
    # 2. Failing that, it will return the value that you specified for the `default`
    # parameter of {#variation} or {#variation_detail}.
    #
    # @return [Boolean] true if the client has been initialized
    #
    def initialized?
      @config.offline? || @config.use_ldd? || @data_source.initialized?
    end

    #
    # Determines the variation of a feature flag to present for a context.
    #
    # @param key [String] the unique feature key for the feature flag, as shown
    #   on the LaunchDarkly dashboard
    # @param context [Hash, LDContext] a hash or LDContext instance describing the context requesting the flag
    # @param default the default value of the flag; this is used if there is an error
    #   condition making it impossible to find or evaluate the flag
    #
    # @return the variation for the provided context, or the default value if there's an an error
    #
    def variation(key, context, default)
      evaluate_internal(key, context, default, false).value
    end

    #
    # Determines the variation of a feature flag for a context, like {#variation}, but also
    # provides additional information about how this value was calculated.
    #
    # The return value of `variation_detail` is an {EvaluationDetail} object, which has
    # three properties: the result value, the positional index of this value in the flag's
    # list of variations, and an object describing the main reason why this value was
    # selected. See {EvaluationDetail} for more on these properties.
    #
    # Calling `variation_detail` instead of `variation` also causes the "reason" data to
    # be included in analytics events, if you are capturing detailed event data for this flag.
    #
    # For more information, see the reference guide on
    # [Evaluation reasons](https://docs.launchdarkly.com/sdk/concepts/evaluation-reasons).
    #
    # @param key [String] the unique feature key for the feature flag, as shown
    #   on the LaunchDarkly dashboard
    # @param context [Hash, LDContext] a hash or object describing the context requesting the flag,
    # @param default the default value of the flag; this is used if there is an error
    #   condition making it impossible to find or evaluate the flag
    #
    # @return [EvaluationDetail] an object describing the result
    #
    def variation_detail(key, context, default)
      evaluate_internal(key, context, default, true)
    end

    #
    # Registers the context. This method simply creates an analytics event containing the context
    # properties, so that LaunchDarkly will know about that context if it does not already.
    #
    # Calling {#variation} or {#variation_detail} also sends the context information to
    # LaunchDarkly (if events are enabled), so you only need to use {#identify} if you
    # want to identify the context without evaluating a flag.
    #
    # Note that event delivery is asynchronous, so the event may not actually be sent
    # until later; see {#flush}.
    #
    # @param context [Hash, LDContext] a hash or object describing the context to register
    # @return [void]
    #
    def identify(context)
      context = LaunchDarkly::Impl::Context.make_context(context)
      unless context.valid?
        @config.logger.warn("Identify called with invalid context: #{context.error}")
        return
      end

      if context.key == ""
        @config.logger.warn("Identify called with empty key")
        return
      end

      @event_processor.record_identify_event(context)
    end

    #
    # Tracks that a context performed an event. This method creates a "custom" analytics event
    # containing the specified event name (key), context properties, and optional data.
    #
    # Note that event delivery is asynchronous, so the event may not actually be sent
    # until later; see {#flush}.
    #
    # As of this version’s release date, the LaunchDarkly service does not support the `metricValue`
    # parameter. As a result, specifying `metricValue` will not yet produce any different behavior
    # from omitting it. Refer to the [SDK reference guide](https://docs.launchdarkly.com/sdk/features/events#ruby)
    # for the latest status.
    #
    # @param event_name [String] The name of the event
    # @param context [Hash, LDContext] a hash or object describing the context to track
    # @param data [Hash] An optional hash containing any additional data associated with the event
    # @param metric_value [Number] A numeric value used by the LaunchDarkly experimentation
    #   feature in numeric custom metrics. Can be omitted if this event is used by only
    #   non-numeric metrics. This field will also be returned as part of the custom event
    #   for Data Export.
    # @return [void]
    #
    def track(event_name, context, data = nil, metric_value = nil)
      context = LaunchDarkly::Impl::Context.make_context(context)
      unless context.valid?
        @config.logger.warn("Track called with invalid context: #{context.error}")
        return
      end

      @event_processor.record_custom_event(context, event_name, data, metric_value)
    end

    #
    # Returns a {FeatureFlagsState} object that encapsulates the state of all feature flags for a given context,
    # including the flag values and also metadata that can be used on the front end. This method does not
    # send analytics events back to LaunchDarkly.
    #
    # @param context [Hash, LDContext] a hash or object describing the context requesting the flags,
    # @param options [Hash] Optional parameters to control how the state is generated
    # @option options [Boolean] :client_side_only (false) True if only flags marked for use with the
    #   client-side SDK should be included in the state. By default, all flags are included.
    # @option options [Boolean] :with_reasons (false) True if evaluation reasons should be included
    #   in the state (see {#variation_detail}). By default, they are not included.
    # @option options [Boolean] :details_only_for_tracked_flags (false) True if any flag metadata that is
    #   normally only used for event generation - such as flag versions and evaluation reasons - should be
    #   omitted for any flag that does not have event tracking or debugging turned on. This reduces the size
    #   of the JSON data if you are passing the flag state to the front end.
    # @return [FeatureFlagsState] a {FeatureFlagsState} object which can be serialized to JSON
    #
    def all_flags_state(context, options={})
      return FeatureFlagsState.new(false) if @config.offline?

      unless initialized?
        if @store.initialized?
            @config.logger.warn { "Called all_flags_state before client initialization; using last known values from data store" }
        else
            @config.logger.warn { "Called all_flags_state before client initialization. Data store not available; returning empty state" }
            return FeatureFlagsState.new(false)
        end
      end

      context = Impl::Context::make_context(context)
      unless context.valid?
        @config.logger.error { "[LDClient] Context was invalid for all_flags_state (#{context.error})" }
        return FeatureFlagsState.new(false)
      end

      begin
        features = @store.all(FEATURES)
      rescue => exn
        Util.log_exception(@config.logger, "Unable to read flags for all_flags_state", exn)
        return FeatureFlagsState.new(false)
      end

      state = FeatureFlagsState.new(true)
      client_only = options[:client_side_only] || false
      with_reasons = options[:with_reasons] || false
      details_only_if_tracked = options[:details_only_for_tracked_flags] || false
      features.each do |k, f|
        if client_only && !f[:clientSide]
          next
        end
        begin
          detail = @evaluator.evaluate(f, context).detail
        rescue => exn
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_EXCEPTION))
          Util.log_exception(@config.logger, "Error evaluating flag \"#{k}\" in all_flags_state", exn)
        end

        requires_experiment_data = experiment?(f, detail.reason)
        flag_state = {
          key: f[:key],
          value: detail.value,
          variation: detail.variation_index,
          reason: detail.reason,
          version: f[:version],
          trackEvents: f[:trackEvents] || requires_experiment_data,
          trackReason: requires_experiment_data,
          debugEventsUntilDate: f[:debugEventsUntilDate],
        }

        state.add_flag(flag_state, with_reasons, details_only_if_tracked)
      end

      state
    end

    #
    # Releases all network connections and other resources held by the client, making it no longer usable.
    #
    # @return [void]
    def close
      @config.logger.info { "[LDClient] Closing LaunchDarkly client..." }
      @data_source.stop
      @event_processor.stop
      @big_segment_store_manager.stop
      @store.stop
      @shared_executor.shutdown
    end

    #
    # Returns an interface for tracking the status of a Big Segment store.
    #
    # The {Interfaces::BigSegmentStoreStatusProvider} has methods for checking whether the Big Segment store
    # is (as far as the SDK knows) currently operational and tracking changes in this status.
    #
    attr_reader :big_segment_store_status_provider

    #
    # Returns an interface for tracking the status of a persistent data store.
    #
    # The {LaunchDarkly::Interfaces::DataStore::StatusProvider} has methods for
    # checking whether the data store is (as far as the SDK knows) currently
    # operational, tracking changes in this status, and getting cache
    # statistics. These are only relevant for a persistent data store; if you
    # are using an in-memory data store, then this method will return a stub
    # object that provides no information.
    #
    # @return [LaunchDarkly::Interfaces::DataStore::StatusProvider]
    #
    attr_reader :data_store_status_provider

    #
    # Returns an interface for tracking the status of the data source.
    #
    # The data source is the mechanism that the SDK uses to get feature flag
    # configurations, such as a streaming connection (the default) or poll
    # requests. The {LaunchDarkly::Interfaces::DataSource::StatusProvider} has
    # methods for checking whether the data source is (as far as the SDK knows)
    # currently operational and tracking changes in this status.
    #
    # @return [LaunchDarkly::Interfaces::DataSource::StatusProvider]
    #
    attr_reader :data_source_status_provider

    #
    # Returns an interface for tracking changes in feature flag configurations.
    #
    # The {LaunchDarkly::Interfaces::FlagTracker} contains methods for
    # requesting notifications about feature flag changes using an event
    # listener model.
    #
    attr_reader :flag_tracker

    private

    def create_default_data_source(sdk_key, config, diagnostic_accumulator)
      if config.offline?
        return NullUpdateProcessor.new
      end
      raise ArgumentError, "sdk_key must not be nil" if sdk_key.nil?  # see LDClient constructor comment on sdk_key
      if config.stream?
        StreamProcessor.new(sdk_key, config, diagnostic_accumulator)
      else
        config.logger.info { "Disabling streaming API" }
        config.logger.warn { "You should only disable the streaming API if instructed to do so by LaunchDarkly support" }
        requestor = Requestor.new(sdk_key, config)
        PollingProcessor.new(config, requestor)
      end
    end

    # @param context [Hash, LDContext]
    # @return [EvaluationDetail]
    def evaluate_internal(key, context, default, with_reasons)
      if @config.offline?
        return Evaluator.error_result(EvaluationReason::ERROR_CLIENT_NOT_READY, default)
      end

      if context.nil?
        @config.logger.error { "[LDClient] Must specify context" }
        detail = Evaluator.error_result(EvaluationReason::ERROR_USER_NOT_SPECIFIED, default)
        return detail
      end

      context = Impl::Context::make_context(context)
      unless context.valid?
        @config.logger.error { "[LDClient] Context was invalid for evaluation of flag '#{key}' (#{context.error}); returning default value" }
        detail = Evaluator.error_result(EvaluationReason::ERROR_USER_NOT_SPECIFIED, default)
        return detail
      end

      unless initialized?
        if @store.initialized?
          @config.logger.warn { "[LDClient] Client has not finished initializing; using last known values from feature store" }
        else
          @config.logger.error { "[LDClient] Client has not finished initializing; feature store unavailable, returning default value" }
          detail = Evaluator.error_result(EvaluationReason::ERROR_CLIENT_NOT_READY, default)
          record_unknown_flag_eval(key, context, default, detail.reason, with_reasons)
          return detail
        end
      end

      begin
        feature = @store.get(FEATURES, key)
      rescue
        # Ignored
      end

      if feature.nil?
        @config.logger.info { "[LDClient] Unknown feature flag \"#{key}\". Returning default value" }
        detail = Evaluator.error_result(EvaluationReason::ERROR_FLAG_NOT_FOUND, default)
        record_unknown_flag_eval(key, context, default, detail.reason, with_reasons)
        return detail
      end

      begin
        res = @evaluator.evaluate(feature, context)
        unless res.prereq_evals.nil?
          res.prereq_evals.each do |prereq_eval|
            record_prereq_flag_eval(prereq_eval.prereq_flag, prereq_eval.prereq_of_flag, context, prereq_eval.detail, with_reasons)
          end
        end
        detail = res.detail
        if detail.default_value?
          detail = EvaluationDetail.new(default, nil, detail.reason)
        end
        record_flag_eval(feature, context, detail, default, with_reasons)
        detail
      rescue => exn
        Util.log_exception(@config.logger, "Error evaluating feature flag \"#{key}\"", exn)
        detail = Evaluator.error_result(EvaluationReason::ERROR_EXCEPTION, default)
        record_flag_eval_error(feature, context, default, detail.reason, with_reasons)
        detail
      end
    end

    private def record_flag_eval(flag, context, detail, default, with_reasons)
      add_experiment_data = experiment?(flag, detail.reason)
      @event_processor.record_eval_event(
        context,
        flag[:key],
        flag[:version],
        detail.variation_index,
        detail.value,
        (add_experiment_data || with_reasons) ? detail.reason : nil,
        default,
        add_experiment_data || flag[:trackEvents] || false,
        flag[:debugEventsUntilDate],
        nil
      )
    end

    private def record_prereq_flag_eval(prereq_flag, prereq_of_flag, context, detail, with_reasons)
      add_experiment_data = experiment?(prereq_flag, detail.reason)
      @event_processor.record_eval_event(
        context,
        prereq_flag[:key],
        prereq_flag[:version],
        detail.variation_index,
        detail.value,
        (add_experiment_data || with_reasons) ? detail.reason : nil,
        nil,
        add_experiment_data || prereq_flag[:trackEvents] || false,
        prereq_flag[:debugEventsUntilDate],
        prereq_of_flag[:key]
      )
    end

    private def record_flag_eval_error(flag, context, default, reason, with_reasons)
      @event_processor.record_eval_event(context, flag[:key], flag[:version], nil, default, with_reasons ? reason : nil, default,
        flag[:trackEvents], flag[:debugEventsUntilDate], nil)
    end

    #
    # @param flag_key [String]
    # @param context [LaunchDarkly::LDContext]
    # @param default [any]
    # @param reason [LaunchDarkly::EvaluationReason]
    # @param with_reasons [Boolean]
    #
    private def record_unknown_flag_eval(flag_key, context, default, reason, with_reasons)
      @event_processor.record_eval_event(context, flag_key, nil, nil, default, with_reasons ? reason : nil, default,
        false, nil, nil)
    end

    private def experiment?(flag, reason)
      return false unless reason

      if reason.in_experiment
        return true
      end

      case reason[:kind]
      when 'RULE_MATCH'
        index = reason[:ruleIndex]
        unless index.nil?
          rules = flag[:rules] || []
          return index >= 0 && index < rules.length && rules[index][:trackEvents]
        end
      when 'FALLTHROUGH'
        return !!flag[:trackEventsFallthrough]
      end
      false
    end
  end

  #
  # Used internally when the client is offline.
  # @private
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
