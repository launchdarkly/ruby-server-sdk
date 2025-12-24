require "ldclient-rb/impl/big_segments"
require "ldclient-rb/impl/broadcaster"
require "ldclient-rb/impl/context"
require "ldclient-rb/impl/data_source"
require "ldclient-rb/impl/data_store"
require "ldclient-rb/impl/data_system/fdv1"
require "ldclient-rb/impl/diagnostic_events"
require "ldclient-rb/impl/evaluation_with_hook_result"
require "ldclient-rb/impl/evaluator"
require "ldclient-rb/impl/flag_tracker"
require "ldclient-rb/impl/migrations/tracker"
require "ldclient-rb/impl/util"
require "ldclient-rb/events"
require "concurrent"
require "concurrent/atomics"
require "digest/sha1"
require "forwardable"
require "logger"
require "securerandom"
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
    extend Forwardable

    def_delegators :@config, :logger

    # @!method flush
    #   Delegates to {LaunchDarkly::EventProcessorMethods#flush}.
    def_delegator :@event_processor, :flush

    # @!method data_store_status_provider
    #   Delegates to the data system {LaunchDarkly::Impl::DataSystem#data_store_status_provider}.
    #   @return [LaunchDarkly::Interfaces::DataStore::StatusProvider]
    # @!method data_source_status_provider
    #   Delegates to the data system {LaunchDarkly::Impl::DataSystem#data_source_status_provider}.
    #   @return [LaunchDarkly::Interfaces::DataSource::StatusProvider]
    def_delegators :@data_system, :data_store_status_provider, :data_source_status_provider

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
      # fail in most configurations. However, there are some configurations where it would be OK to
      # not provide a SDK key.
      #   * Offline mode
      #   * Using LDD mode with events disabled
      #   * Using a custom data source (like FileData) with events disabled
      if !config.offline? && sdk_key.nil?
        # If the data source is nil we create a default data source which requires the SDK key.
        if config.send_events || (!config.use_ldd? && config.data_source.nil?)
          raise ArgumentError, "sdk_key must not be nil"
        end
      end

      @sdk_key = sdk_key
      config.instance_id = SecureRandom.uuid
      @config = config

      start_up(wait_for_sec)
    end

    #
    # Re-initializes an existing client after a process fork.
    #
    # The SDK relies on multiple background threads to operate correctly. When a process forks, `these threads are not
    # available to the child <https://apidock.com/ruby/Process/fork/class>`.
    #
    # As a result, the SDK will not function correctly in the child process until it is re-initialized.
    #
    # This method is effectively equivalent to instantiating a new client. Future iterations of the SDK will provide
    # increasingly efficient re-initializing improvements.
    #
    # Note that any configuration provided to the SDK will need to survive the forking process independently. For this
    # reason, it is recommended that any listener or hook integrations be added postfork unless you are certain it can
    # survive the forking process.
    #
    # @param wait_for_sec [Float] maximum time (in seconds) to wait for initialization
    #
    def postfork(wait_for_sec = 5)
      @data_system = nil
      @event_processor = nil
      @big_segment_store_manager = nil
      @flag_tracker = nil

      start_up(wait_for_sec)
    end

    private def start_up(wait_for_sec)
      environment_metadata = get_environment_metadata
      plugin_hooks = get_plugin_hooks(environment_metadata)

      @hooks = Concurrent::Array.new(@config.hooks + plugin_hooks)

      # Initialize the data system (FDv1 for now, will support FDv2 in the future)
      # Note: FDv1 will update @config.feature_store to use its wrapped store
      @data_system = Impl::DataSystem::FDv1.new(@sdk_key, @config)

      # Components not managed by data system
      @big_segment_store_manager = Impl::BigSegmentStoreManager.new(@config.big_segments, @config.logger)
      @big_segment_store_status_provider = @big_segment_store_manager.status_provider

      get_flag = lambda { |key| @data_system.store.get(Impl::DataStore::FEATURES, key) }
      get_segment = lambda { |key| @data_system.store.get(Impl::DataStore::SEGMENTS, key) }
      get_big_segments_membership = lambda { |key| @big_segment_store_manager.get_context_membership(key) }
      @evaluator = LaunchDarkly::Impl::Evaluator.new(get_flag, get_segment, get_big_segments_membership, @config.logger)

      if !@config.offline? && @config.send_events && !@config.diagnostic_opt_out?
        diagnostic_accumulator = Impl::DiagnosticAccumulator.new(Impl::DiagnosticAccumulator.create_diagnostic_id(@sdk_key))
        @data_system.set_diagnostic_accumulator(diagnostic_accumulator)
      else
        diagnostic_accumulator = nil
      end

      if @config.offline? || !@config.send_events
        @event_processor = NullEventProcessor.new
      else
        @event_processor = EventProcessor.new(@sdk_key, @config, nil, diagnostic_accumulator)
      end

      # Create the flag tracker using the broadcaster from the data system
      eval_fn = lambda { |key, context| variation(key, context, nil) }
      @flag_tracker = Impl::FlagTracker.new(@data_system.flag_change_broadcaster, eval_fn)

      register_plugins(environment_metadata)

      # Start the data system
      ready = @data_system.start

      return unless wait_for_sec > 0

      if wait_for_sec > 60
        @config.logger.warn { "[LDClient] Client was configured to block for up to #{wait_for_sec} seconds when initializing. We recommend blocking no longer than 60." }
      end

      ok = ready.wait(wait_for_sec)
      if !ok
        @config.logger.error { "[LDClient] Timeout encountered waiting for LaunchDarkly client initialization" }
      elsif !initialized?
        @config.logger.error { "[LDClient] LaunchDarkly client initialization failed" }
      end
    end

    private def get_environment_metadata
      sdk_metadata = Interfaces::Plugins::SdkMetadata.new(
        name: "ruby-server-sdk",
        version: LaunchDarkly::VERSION,
        wrapper_name: @config.wrapper_name,
        wrapper_version: @config.wrapper_version
      )

      application_metadata = nil
      if @config.application && !@config.application.empty?
        application_metadata = Interfaces::Plugins::ApplicationMetadata.new(
          id: @config.application[:id],
          version: @config.application[:version]
        )
      end

      Interfaces::Plugins::EnvironmentMetadata.new(
        sdk: sdk_metadata,
        application: application_metadata,
        sdk_key: @sdk_key
      )
    end

    private def get_plugin_hooks(environment_metadata)
      hooks = []
      @config.plugins.each do |plugin|
        hooks.concat(plugin.get_hooks(environment_metadata))
      rescue => e
          @config.logger.error { "[LDClient] Error getting hooks from plugin #{plugin.metadata.name}: #{e}" }
      end
      hooks
    end

    private def register_plugins(environment_metadata)
      @config.plugins.each do |plugin|
        plugin.register(self, environment_metadata)
      rescue => e
        @config.logger.error { "[LDClient] Error registering plugin #{plugin.metadata.name}: #{e}" }
      end
    end

    #
    # Add a hook to the client. In order to register a hook before the client starts, please use the `hooks` property of
    # {#LDConfig}.
    #
    # Hooks provide entrypoints which allow for observation of SDK functions.
    #
    # @param hook [Interfaces::Hooks::Hook]
    #
    def add_hook(hook)
      unless hook.is_a?(Interfaces::Hooks::Hook)
        @config.logger.error { "[LDClient] Attempted to add a hook that does not include the LaunchDarkly::Intefaces::Hooks::Hook mixin. Ignoring." }
        return
      end

      @hooks.push(hook)
    end

    #
    # Creates a hash string that can be used by the JavaScript SDK to identify a context.
    # For more information, see [Secure mode](https://docs.launchdarkly.com/sdk/features/secure-mode#ruby).
    #
    # @param context [Hash, LDContext]
    # @return [String, nil] a hash string or nil if the provided context was invalid
    #
    def secure_mode_hash(context)
      context = Impl::Context.make_context(context)
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
      @data_system.data_availability == @data_system.target_availability
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
    # @return the variation for the provided context, or the default value if there's an error
    #
    def variation(key, context, default)
      context = Impl::Context::make_context(context)
      result = evaluate_with_hooks(key, context, default, :variation) do
        detail, _, _ = variation_with_flag(key, context, default)
        LaunchDarkly::Impl::EvaluationWithHookResult.new(detail)
      end

      result.evaluation_detail.value
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
      context = Impl::Context::make_context(context)
      result = evaluate_with_hooks(key, context, default, :variation_detail) do
        detail, _, _ = evaluate_internal(key, context, default, true)
        LaunchDarkly::Impl::EvaluationWithHookResult.new(detail)
      end

      result.evaluation_detail
    end

    #
    # evaluate_with_hook will run the provided block, wrapping it with evaluation hook support.
    #
    # Example:
    #
    # ```ruby
    # evaluate_with_hooks(key, context, default, method) do
    #   puts 'This is being wrapped with evaluation hooks'
    # end
    # ```
    #
    # @param key [String]
    # @param context [LDContext]
    # @param default [any]
    # @param method [Symbol]
    # @param &block [#call] Implicit passed block
    #
    # @return [LaunchDarkly::Impl::EvaluationWithHookResult]
    #
    private def evaluate_with_hooks(key, context, default, method)
      return yield if @hooks.empty?

      hooks, evaluation_series_context = prepare_hooks(key, context, default, method)
      hook_data = execute_before_evaluation(hooks, evaluation_series_context)
      evaluation_result = yield
      execute_after_evaluation(hooks, evaluation_series_context, hook_data, evaluation_result.evaluation_detail)

      evaluation_result
    end

    #
    # Execute the :before_evaluation stage of the evaluation series.
    #
    # This method will return the results of each hook, indexed into an array in the same order as the hooks. If a hook
    # raised an uncaught exception, the value will be nil.
    #
    # @param hooks [Array<Interfaces::Hooks::Hook>]
    # @param evaluation_series_context [EvaluationSeriesContext]
    #
    # @return [Array<any>]
    #
    private def execute_before_evaluation(hooks, evaluation_series_context)
      hooks.map do |hook|
        try_execute_stage(:before_evaluation, hook.metadata.name) do
          hook.before_evaluation(evaluation_series_context, {})
        end
      end
    end

    #
    # Execute the :after_evaluation stage of the evaluation series.
    #
    # This method will return the results of each hook, indexed into an array in the same order as the hooks. If a hook
    # raised an uncaught exception, the value will be nil.
    #
    # @param hooks [Array<Interfaces::Hooks::Hook>]
    # @param evaluation_series_context [EvaluationSeriesContext]
    # @param hook_data [Array<any>]
    # @param evaluation_detail [EvaluationDetail]
    #
    # @return [Array<any>]
    #
    private def execute_after_evaluation(hooks, evaluation_series_context, hook_data, evaluation_detail)
      hooks.zip(hook_data).reverse.map do |(hook, data)|
        try_execute_stage(:after_evaluation, hook.metadata.name) do
          hook.after_evaluation(evaluation_series_context, data, evaluation_detail)
        end
      end
    end

    #
    # Try to execute the provided block. If execution raises an exception, catch and log it, then move on with
    # execution.
    #
    # @return [any]
    #
    private def try_execute_stage(method, hook_name)
      yield
    rescue => e
      @config.logger.error { "[LDClient] An error occurred in #{method} of the hook #{hook_name}: #{e}" }
      nil
    end

    #
    # Return a copy of the existing hooks and a few instance of the EvaluationSeriesContext used for the evaluation series.
    #
    # @param key [String]
    # @param context [LDContext]
    # @param default [any]
    # @param method [Symbol]
    # @return [Array[Array<Interfaces::Hooks::Hook>, Interfaces::Hooks::EvaluationSeriesContext]]
    #
    private def prepare_hooks(key, context, default, method)
      # Copy the hooks to use a consistent set during the evaluation series.
      #
      # Hooks can be added and we want to ensure all correct stages for a given hook execute. For example, we do not
      # want to trigger the after_evaluation method without also triggering the before_evaluation method.
      hooks = @hooks.dup
      evaluation_series_context = Interfaces::Hooks::EvaluationSeriesContext.new(key, context, default, method)

      [hooks, evaluation_series_context]
    end

    #
    # This method returns the migration stage of the migration feature flag for the given evaluation context.
    #
    # This method returns the default stage if there is an error or the flag does not exist. If the default stage is not
    # a valid stage, then a default stage of 'off' will be used instead.
    #
    # @param key [String]
    # @param context [LDContext]
    # @param default_stage [Symbol]
    #
    # @return [Array<Symbol, Interfaces::Migrations::OpTracker>]
    #
    def migration_variation(key, context, default_stage)
      unless Migrations::VALID_STAGES.include? default_stage
        @config.logger.error { "[LDClient] default_stage #{default_stage} is not a valid stage; continuing with 'off' as default" }
        default_stage = Migrations::STAGE_OFF
      end

      context = Impl::Context::make_context(context)
      result = evaluate_with_hooks(key, context, default_stage, :migration_variation) do
        detail, flag, _ = variation_with_flag(key, context, default_stage.to_s)

        stage = detail.value
        stage = stage.to_sym if stage.respond_to? :to_sym

        if Migrations::VALID_STAGES.include?(stage)
          tracker = Impl::Migrations::OpTracker.new(@config.logger, key, flag, context, detail, default_stage)
          next LaunchDarkly::Impl::EvaluationWithHookResult.new(detail, {stage: stage, tracker: tracker})
        end

        detail = LaunchDarkly::Impl::Evaluator.error_result(LaunchDarkly::EvaluationReason::ERROR_WRONG_TYPE, default_stage.to_s)
        tracker = Impl::Migrations::OpTracker.new(@config.logger, key, flag, context, detail, default_stage)

        LaunchDarkly::Impl::EvaluationWithHookResult.new(detail, {stage: default_stage, tracker: tracker})
      end

      [result.results[:stage], result.results[:tracker]]
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
    # Tracks the results of a migrations operation. This event includes measurements which can be used to enhance the
    # observability of a migration within the LaunchDarkly UI.
    #
    # This event should be generated through {Interfaces::Migrations::OpTracker}. If you are using the
    # {Interfaces::Migrations::Migrator} to handle migrations, this event will be created and emitted
    # automatically.
    #
    # @param tracker [LaunchDarkly::Interfaces::Migrations::OpTracker]
    #
    def track_migration_op(tracker)
      unless tracker.is_a? LaunchDarkly::Interfaces::Migrations::OpTracker
        @config.logger.error { "invalid op tracker received in track_migration_op" }
        return
      end

      event = tracker.build
      if event.is_a? String
        @config.logger.error { "[LDClient] Error occurred generating migration op event; #{event}" }
        return
      end


      @event_processor.record_migration_op_event(event)
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
        if @data_system.store.initialized?
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
        features = @data_system.store.all(Impl::DataStore::FEATURES)
      rescue => exn
        Impl::Util.log_exception(@config.logger, "Unable to read flags for all_flags_state", exn)
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
          (eval_result, eval_state) = @evaluator.evaluate(f, context)
          detail = eval_result.detail
        rescue => exn
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_EXCEPTION))
          Impl::Util.log_exception(@config.logger, "Error evaluating flag \"#{k}\" in all_flags_state", exn)
        end

        requires_experiment_data = experiment?(f, detail.reason)
        flag_state = {
          key: f[:key],
          value: detail.value,
          variation: detail.variation_index,
          reason: detail.reason,
          prerequisites: eval_state.prerequisites,
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
      @data_system.stop
      @event_processor.stop
      @big_segment_store_manager.stop
    end

    #
    # Returns an interface for tracking the status of a Big Segment store.
    #
    # The {Interfaces::BigSegmentStoreStatusProvider} has methods for checking whether the Big Segment store
    # is (as far as the SDK knows) currently operational and tracking changes in this status.
    #
    attr_reader :big_segment_store_status_provider

    #
    # Returns an interface for tracking changes in feature flag configurations.
    #
    # The {LaunchDarkly::Interfaces::FlagTracker} contains methods for
    # requesting notifications about feature flag changes using an event
    # listener model.
    #
    def flag_tracker
      @flag_tracker
    end

    #
    # @param key [String]
    # @param context [LDContext]
    # @param default [Object]
    #
    # @return [Array<EvaluationDetail, [LaunchDarkly::Impl::Model::FeatureFlag, nil], [String, nil]>]
    #
    private def variation_with_flag(key, context, default)
      evaluate_internal(key, context, default, false)
    end

    #
    # @param key [String]
    # @param context [LDContext]
    # @param default [Object]
    # @param with_reasons [Boolean]
    #
    # @return [Array<EvaluationDetail, [LaunchDarkly::Impl::Model::FeatureFlag, nil], [String, nil]>]
    #
    private def evaluate_internal(key, context, default, with_reasons)
      if @config.offline?
        return Evaluator.error_result(EvaluationReason::ERROR_CLIENT_NOT_READY, default), nil, nil
      end

      if context.nil?
        @config.logger.error { "[LDClient] Must specify context" }
        detail = Evaluator.error_result(EvaluationReason::ERROR_USER_NOT_SPECIFIED, default)
        return detail, nil, "no context provided"
      end

      unless context.valid?
        @config.logger.error { "[LDClient] Context was invalid for evaluation of flag '#{key}' (#{context.error}); returning default value" }
        detail = Evaluator.error_result(EvaluationReason::ERROR_USER_NOT_SPECIFIED, default)
        return detail, nil, context.error
      end

      unless initialized?
        if @data_system.store.initialized?
          @config.logger.warn { "[LDClient] Client has not finished initializing; using last known values from feature store" }
        else
          @config.logger.error { "[LDClient] Client has not finished initializing; feature store unavailable, returning default value" }
          detail = Evaluator.error_result(EvaluationReason::ERROR_CLIENT_NOT_READY, default)
          record_unknown_flag_eval(key, context, default, detail.reason, with_reasons)
          return detail, nil, "client not initialized"
        end
      end

      begin
        feature = @data_system.store.get(Impl::DataStore::FEATURES, key)
      rescue
        # Ignored
      end

      if feature.nil?
        @config.logger.info { "[LDClient] Unknown feature flag \"#{key}\". Returning default value" }
        detail = Evaluator.error_result(EvaluationReason::ERROR_FLAG_NOT_FOUND, default)
        record_unknown_flag_eval(key, context, default, detail.reason, with_reasons)
        return detail, nil, "feature flag not found"
      end

      begin
        (res, _) = @evaluator.evaluate(feature, context)
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
        [detail, feature, nil]
      rescue => exn
        Impl::Util.log_exception(@config.logger, "Error evaluating feature flag \"#{key}\"", exn)
        detail = Evaluator.error_result(EvaluationReason::ERROR_EXCEPTION, default)
        record_flag_eval_error(feature, context, default, detail.reason, with_reasons)
        [detail, feature, exn.to_s]
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
        nil,
        flag[:samplingRatio],
        !!flag[:excludeFromSummaries]
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
        prereq_of_flag[:key],
        prereq_flag[:samplingRatio],
        !!prereq_flag[:excludeFromSummaries]
      )
    end

    private def record_flag_eval_error(flag, context, default, reason, with_reasons)
      @event_processor.record_eval_event(context, flag[:key], flag[:version], nil, default, with_reasons ? reason : nil, default,
        flag[:trackEvents], flag[:debugEventsUntilDate], nil, flag[:samplingRatio], !!flag[:excludeFromSummaries])
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
        false, nil, nil, 1, false)
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
end
