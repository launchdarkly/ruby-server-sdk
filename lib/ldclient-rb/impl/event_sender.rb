require "securerandom"

module LaunchDarkly
  module Impl
    EventSenderResult = Struct.new(:success, :must_shutdown, :time_from_server)

    class EventSender
      CURRENT_SCHEMA_VERSION = 3
      DEFAULT_RETRY_INTERVAL = 1

      def initialize(sdk_key, config, http_client = nil, retry_interval = DEFAULT_RETRY_INTERVAL)
        @client = http_client ? http_client : LaunchDarkly::Util.new_http_client(config.events_uri, config)
        @sdk_key = sdk_key
        @config = config
        @events_uri = config.events_uri + "/bulk"
        @diagnostic_uri = config.events_uri + "/diagnostic"
        @logger = config.logger
        @retry_interval = retry_interval
      end

      def send_event_data(event_data, description, is_diagnostic)
        uri = is_diagnostic ? @diagnostic_uri : @events_uri
        payload_id = is_diagnostic ? nil : SecureRandom.uuid
        res = nil
        (0..1).each do |attempt|
          if attempt > 0
            @logger.warn { "[LDClient] Will retry posting events after #{@retry_interval} second" }
            sleep(@retry_interval)
          end
          begin
            @client.start if !@client.started?
            @logger.debug { "[LDClient] sending #{description}: #{event_data}" }
            req = Net::HTTP::Post.new(uri)
            req.content_type = "application/json"
            req.body = event_data
            Impl::Util.default_http_headers(@sdk_key, @config).each { |k, v| req[k] = v }
            if !is_diagnostic
              req["X-LaunchDarkly-Event-Schema"] = CURRENT_SCHEMA_VERSION.to_s
              req["X-LaunchDarkly-Payload-ID"] = payload_id
            end
            req["Connection"] = "keep-alive"
            res = @client.request(req)
          rescue StandardError => exn
            @logger.warn { "[LDClient] Error sending events: #{exn.inspect}." }
            next
          end
          status = res.code.to_i
          if status >= 200 && status < 300
            res_time = nil
            if !res["date"].nil?
              begin
                res_time = Time.httpdate(res["date"])
              rescue ArgumentError
              end
            end
            return EventSenderResult.new(true, false, res_time)
          end
          must_shutdown = !LaunchDarkly::Util.http_error_recoverable?(status)
          can_retry = !must_shutdown && attempt == 0
          message = LaunchDarkly::Util.http_error_message(status, "event delivery", can_retry ? "will retry" : "some events were dropped")
          @logger.error { "[LDClient] #{message}" }
          if must_shutdown
            return EventSenderResult.new(false, true, nil)
          end
        end
        # used up our retries
        return EventSenderResult.new(false, false, nil)
      end
    end
  end
end
