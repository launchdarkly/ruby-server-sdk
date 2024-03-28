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

    if config[:streaming]
      streaming = config[:streaming]
      opts[:stream_uri] = streaming[:baseUri] unless streaming[:baseUri].nil?
      opts[:payload_filter_key] = streaming[:filter] unless streaming[:filter].nil?
      opts[:initial_reconnect_delay] = streaming[:initialRetryDelayMs] / 1_000.0 unless streaming[:initialRetryDelayMs].nil?
    elsif config[:polling]
      polling = config[:polling]
      opts[:stream] = false
      opts[:base_uri] = polling[:baseUri] unless polling[:baseUri].nil?
      opts[:payload_filter_key] = polling[:filter] unless polling[:filter].nil?
      opts[:poll_interval] = polling[:pollIntervalMs] / 1_000.0 unless polling[:pollIntervalMs].nil?
    end

    if config[:events]
      events = config[:events]
      opts[:events_uri] = events[:baseUri] if events[:baseUri]
      opts[:capacity] = events[:capacity] if events[:capacity]
      opts[:diagnostic_opt_out] = !events[:enableDiagnostics]
      opts[:all_attributes_private] = !!events[:allAttributesPrivate]
      opts[:private_attributes] = events[:globalPrivateAttributes]
      opts[:flush_interval] = (events[:flushIntervalMs] / 1_000) unless events[:flushIntervalMs].nil?
    else
      opts[:send_events] = false
    end

    if config[:bigSegments]
      big_segments = config[:bigSegments]

      store = BigSegmentStoreFixture.new(config[:bigSegments][:callbackUri])
      context_cache_time = big_segments[:userCacheTimeMs].nil? ? nil : big_segments[:userCacheTimeMs] / 1_000
      status_poll_interval_ms = big_segments[:statusPollIntervalMs].nil? ? nil : big_segments[:statusPollIntervalMs] / 1_000
      stale_after_ms = big_segments[:staleAfterMs].nil? ? nil : big_segments[:staleAfterMs] / 1_000

      opts[:big_segments] = LaunchDarkly::BigSegmentsConfig.new(
        store: store,
        context_cache_size: big_segments[:userCacheSize],
        context_cache_time: context_cache_time,
        status_poll_interval: status_poll_interval_ms,
        stale_after: stale_after_ms
      )
    end

    if config[:tags]
      opts[:application] = {
        :id => config[:tags][:applicationId],
        :version => config[:tags][:applicationVersion],
      }
    end

    if config[:hooks]
      opts[:hooks] = config[:hooks][:hooks].map do |hook|
        Hook.new(hook[:name], hook[:callbackUri], hook[:data] || {})
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
end
