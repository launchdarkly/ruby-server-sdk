require 'ld-eventsource'
require 'json'
require 'net/http'

class ClientEntity
  def initialize(log, config)
    @log = log

    opts = {}

    opts[:logger] = log

    if config[:streaming]
      streaming = config[:streaming]
      opts[:stream_uri] = streaming[:baseUri] if !streaming[:baseUri].nil?
      opts[:initial_reconnect_delay] = streaming[:initialRetryDelayMs] / 1_000.0 if !streaming[:initialRetryDelayMs].nil?
    elsif config[:polling]
      polling = config[:polling]
      opts[:stream] = false
      opts[:base_uri] = polling[:baseUri] if !polling[:baseUri].nil?
      opts[:poll_interval] = polling[:pollIntervalMs] / 1_000.0 if !polling[:pollIntervalMs].nil?
    end

    if config[:events]
      events = config[:events]
      opts[:events_uri] = events[:baseUri] if events[:baseUri]
      opts[:capacity] = events[:capacity] if events[:capacity]
      opts[:diagnostic_opt_out] = !events[:enableDiagnostics]
      opts[:all_attributes_private]  = !!events[:allAttributesPrivate]
      opts[:private_attribute_names] = events[:globalPrivateAttributes]
      opts[:flush_interval] = (events[:flushIntervalMs] / 1_000) if !events[:flushIntervalMs].nil?
      opts[:inline_users_in_events] = events[:inlineUsers] || false
    else
      opts[:send_events] = false
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
      detail = @client.variation_detail(params[:flagKey], params[:user], params[:defaultValue])
      response[:value] = detail.value
      response[:variationIndex] = detail.variation_index
      response[:reason] = detail.reason
    else
      response[:value] = @client.variation(params[:flagKey], params[:user], params[:defaultValue])
    end

    response
  end

  def evaluate_all(params)
    opts = {}
    opts[:client_side_only] = params[:clientSideOnly] || false
    opts[:with_reasons] = params[:withReasons] || false
    opts[:details_only_for_tracked_flags] = params[:detailsOnlyForTrackedFlags] || false

    @client.all_flags_state(params[:user], opts)
  end

  def track(params)
    @client.track(params[:eventKey], params[:user], params[:data], params[:metricValue])
  end

  def identify(params)
    @client.identify(params[:user])
  end

  def flush_events
    @client.flush
  end

  def log
    @log
  end

  def close
    @client.close
    @log.info("Test ended")
  end
end
