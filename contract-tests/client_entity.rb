require 'ld-eventsource'
require 'json'
require 'net/http'
require 'launchdarkly-server-sdk'
require './big_segment_store_fixture'
require './hook'
require 'http'

class ClientEntity
  def initialize(log, config)
    @log = log

    opts = {}

    opts[:logger] = log

    data_system_config = config[:dataSystem]
    if data_system_config
      data_system = LaunchDarkly::DataSystem.custom

      init_configs = data_system_config[:initializers]
      if init_configs
        initializers = []
        init_configs.each do |init_config|
          polling = init_config[:polling]
          next unless polling

          opts[:base_uri] = polling[:baseUri] if polling[:baseUri]
          set_optional_time_prop(polling, :pollIntervalMs, opts, :poll_interval)
          initializers << LaunchDarkly::DataSystem.polling_ds_builder
        end
        data_system.initializers(initializers)
      end

      sync_config = data_system_config[:synchronizers]
      if sync_config
        primary = sync_config[:primary]
        secondary = sync_config[:secondary]

        primary_builder = nil
        secondary_builder = nil

        if primary
          streaming = primary[:streaming]
          if streaming
            opts[:stream_uri] = streaming[:baseUri] if streaming[:baseUri]
            set_optional_time_prop(streaming, :initialRetryDelayMs, opts, :initial_reconnect_delay)
            primary_builder = LaunchDarkly::DataSystem.streaming_ds_builder
          elsif primary[:polling]
            polling = primary[:polling]
            opts[:base_uri] = polling[:baseUri] if polling[:baseUri]
            set_optional_time_prop(polling, :pollIntervalMs, opts, :poll_interval)
            primary_builder = LaunchDarkly::DataSystem.polling_ds_builder
          end
        end

        if secondary
          streaming = secondary[:streaming]
          if streaming
            opts[:stream_uri] = streaming[:baseUri] if streaming[:baseUri]
            set_optional_time_prop(streaming, :initialRetryDelayMs, opts, :initial_reconnect_delay)
            secondary_builder = LaunchDarkly::DataSystem.streaming_ds_builder
          elsif secondary[:polling]
            polling = secondary[:polling]
            opts[:base_uri] = polling[:baseUri] if polling[:baseUri]
            set_optional_time_prop(polling, :pollIntervalMs, opts, :poll_interval)
            secondary_builder = LaunchDarkly::DataSystem.polling_ds_builder
          end
        end

        data_system.synchronizers(primary_builder, secondary_builder) if primary_builder

        # Always configure FDv1 fallback when synchronizers are present
        # The fallback is triggered by the LD-FD-Fallback header from the server
        if primary_builder || secondary_builder
          fallback_builder = LaunchDarkly::DataSystem.fdv1_fallback_ds_builder
          data_system.fdv1_compatible_synchronizer(fallback_builder)
        end
      end

      if data_system_config[:payloadFilter]
        opts[:payload_filter_key] = data_system_config[:payloadFilter]
      end

      opts[:data_system_config] = data_system.build
    elsif config[:streaming]
      streaming = config[:streaming]
      opts[:stream_uri] = streaming[:baseUri] unless streaming[:baseUri].nil?
      opts[:payload_filter_key] = streaming[:filter] unless streaming[:filter].nil?
      set_optional_time_prop(streaming, :initialRetryDelayMs, opts, :initial_reconnect_delay)
    elsif config[:polling]
      polling = config[:polling]
      opts[:stream] = false
      opts[:base_uri] = polling[:baseUri] unless polling[:baseUri].nil?
      opts[:payload_filter_key] = polling[:filter] unless polling[:filter].nil?
      set_optional_time_prop(polling, :pollIntervalMs, opts, :poll_interval)
    else
      opts[:use_ldd] = true
    end

    if config[:persistentDataStore]
      store_config = {}
      store_config[:prefix] = config[:persistentDataStore][:store][:prefix] if config[:persistentDataStore][:store][:prefix]

      case config[:persistentDataStore][:cache][:mode]
        when 'off'
          store_config[:expiration] = 0
        when 'infinite'
          # NOTE: We don't actually support infinite cache mode, so we'll just set it to nil for now. This uses a default
          # 15 second expiration time in the SDK, which is long enough to pass any test.
          store_config[:expiration] = nil
        when 'ttl'
          store_config[:expiration] = config[:persistentDataStore][:cache][:ttl]
      end

      case config[:persistentDataStore][:store][:type]
      when 'redis'
        store_config[:redis_url] = config[:persistentDataStore][:store][:dsn]
        store = LaunchDarkly::Integrations::Redis.new_feature_store(store_config)
        opts[:feature_store] = store
      when 'consul'
        store_config[:url] = config[:persistentDataStore][:store][:url]
        store = LaunchDarkly::Integrations::Consul.new_feature_store(store_config)
        opts[:feature_store] = store
      when 'dynamodb'
        client = Aws::DynamoDB::Client.new(
          region: 'us-east-1',
          credentials: Aws::Credentials.new('dummy', 'dummy', 'dummy'),
          endpoint: config[:persistentDataStore][:store][:dsn]
        )
        store_config[:existing_client] = client
        store = LaunchDarkly::Integrations::DynamoDB.new_feature_store('sdk-contract-tests', store_config)
        opts[:feature_store] = store
      end
    end

    if config[:events]
      events = config[:events]
      opts[:events_uri] = events[:baseUri] if events[:baseUri]
      opts[:capacity] = events[:capacity] if events[:capacity]
      opts[:diagnostic_opt_out] = !events[:enableDiagnostics]
      opts[:all_attributes_private] = !!events[:allAttributesPrivate]
      opts[:private_attributes] = events[:globalPrivateAttributes]
      set_optional_time_prop(events, :flushIntervalMs, opts, :flush_interval)
      opts[:omit_anonymous_contexts] = !!events[:omitAnonymousContexts]
      opts[:compress_events] = !!events[:enableGzip]
    else
      opts[:send_events] = false
    end

    if config[:bigSegments]
      big_segments = config[:bigSegments]
      big_config = { store: BigSegmentStoreFixture.new(big_segments[:callbackUri]) }

      big_config[:context_cache_size] = big_segments[:userCacheSize] if big_segments[:userCacheSize]
      set_optional_time_prop(big_segments, :userCacheTimeMs, big_config, :context_cache_time)
      set_optional_time_prop(big_segments, :statusPollIntervalMs, big_config, :status_poll_interval)
      set_optional_time_prop(big_segments, :staleAfterMs, big_config, :stale_after)

      opts[:big_segments] = LaunchDarkly::BigSegmentsConfig.new(**big_config)
    end

    if config[:tags]
      opts[:application] = {
        :id => config[:tags][:applicationId],
        :version => config[:tags][:applicationVersion],
      }
    end

    if config[:hooks]
      opts[:hooks] = config[:hooks][:hooks].map do |hook|
        Hook.new(hook[:name], hook[:callbackUri], hook[:data] || {}, hook[:errors] || {})
      end
    end

    startWaitTimeMs = config[:startWaitTimeMs] || 5_000

    @client = LaunchDarkly::LDClient.new(
      config[:credential],
      LaunchDarkly::Config.new(opts),
      startWaitTimeMs / 1_000.0)
  end

  def initialized?
    @client.initialized?
  end

  def evaluate(params)
    response = {}

    if params[:detail]
      detail = @client.variation_detail(params[:flagKey], params[:context], params[:defaultValue])
      response[:value] = detail.value
      response[:variationIndex] = detail.variation_index
      response[:reason] = detail.reason
    else
      response[:value] = @client.variation(params[:flagKey], params[:context], params[:defaultValue])
    end

    response
  end

  def evaluate_all(params)
    opts = {}
    opts[:client_side_only] = params[:clientSideOnly] || false
    opts[:with_reasons] = params[:withReasons] || false
    opts[:details_only_for_tracked_flags] = params[:detailsOnlyForTrackedFlags] || false

    @client.all_flags_state(params[:context], opts)
  end

  def migration_variation(params)
    default_stage = params[:defaultStage]
    default_stage = default_stage.to_sym if default_stage.respond_to? :to_sym
    stage, _ = @client.migration_variation(params[:key], params[:context], default_stage)
    stage
  end

  def migration_operation(params)
    builder = LaunchDarkly::Migrations::MigratorBuilder.new(@client)
    builder.read_execution_order(params[:readExecutionOrder].to_sym)
    builder.track_latency(params[:trackLatency])
    builder.track_errors(params[:trackErrors])

    callback = ->(endpoint) {
      ->(payload) {
        response = HTTP.post(endpoint, body: payload)

        if response.status.success?
          LaunchDarkly::Result.success(response.body.to_s)
        else
          LaunchDarkly::Result.fail("requested failed with status code #{response.status}")
        end
      }
    }

    consistency = nil
    if params[:trackConsistency]
      consistency = ->(lhs, rhs) { lhs == rhs }
    end

    builder.read(callback.call(params[:oldEndpoint]), callback.call(params[:newEndpoint]), consistency)
    builder.write(callback.call(params[:oldEndpoint]), callback.call(params[:newEndpoint]))

    migrator = builder.build

    return migrator if migrator.is_a? String

    if params[:operation] == LaunchDarkly::Migrations::OP_READ.to_s
      result = migrator.read(params[:key], params[:context], params[:defaultStage].to_sym, params[:payload])
      result.success? ? result.value : result.error
    else
      result = migrator.write(params[:key], params[:context], params[:defaultStage].to_sym, params[:payload])
      result.authoritative.success? ? result.authoritative.value : result.authoritative.error
    end
  end

  def context_comparison(params)
    context1 = build_context_from_params(params[:context1])
    context2 = build_context_from_params(params[:context2])

    context1 == context2
  end

  def secure_mode_hash(params)
    @client.secure_mode_hash(params[:context])
  end

  def track(params)
    @client.track(params[:eventKey], params[:context], params[:data], params[:metricValue])
  end

  def identify(params)
    @client.identify(params[:context])
  end

  def flush_events
    @client.flush
  end

  def get_big_segment_store_status
    status = @client.big_segment_store_status_provider.status
    { available: status.available, stale: status.stale }
  end

  def log
    @log
  end

  def close
    @client.close
    @log.info("Test ended")
  end

  #
  # Helper to convert millisecond time properties to seconds.
  # Only sets the output if the input value is present.
  #
  # @param params_in [Hash] Input parameters hash
  # @param name_in [Symbol] Key name in input hash (e.g., :pollIntervalMs)
  # @param params_out [Hash] Output parameters hash
  # @param name_out [Symbol] Key name in output hash (e.g., :poll_interval)
  #
  private def set_optional_time_prop(params_in, name_in, params_out, name_out)
    value = params_in[name_in]
    params_out[name_out] = value / 1_000.0 if value
  end

  private def build_context_from_params(params)
    return build_single_context_from_attribute_definitions(params[:single]) unless params[:single].nil?

    contexts = params[:multi].map do |param|
      build_single_context_from_attribute_definitions(param)
    end

    LaunchDarkly::LDContext.create_multi(contexts)
  end

  private def build_single_context_from_attribute_definitions(params)
    context = {kind: params[:kind], key: params[:key]}

    params[:attributes]&.each do |attribute|
      context[attribute[:name]] = attribute[:value]
    end

    if params[:privateAttributes]
      context[:_meta] = {
        privateAttributes: params[:privateAttributes].map do |attribute|
          if attribute[:literal]
            LaunchDarkly::Reference.create_literal(attribute[:value])
          else
            LaunchDarkly::Reference.create(attribute[:value])
          end
        end,
      }
    end

    LaunchDarkly::LDContext.create(context)
  end
end
