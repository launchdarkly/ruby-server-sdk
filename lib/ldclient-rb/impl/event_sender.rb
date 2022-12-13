require "ldclient-rb/impl/unbounded_pool"

require "securerandom"
require "http"

module LaunchDarkly
  module Impl
    EventSenderResult = Struct.new(:success, :must_shutdown, :time_from_server)

    class EventSender
      CURRENT_SCHEMA_VERSION = 4
      DEFAULT_RETRY_INTERVAL = 1

      def initialize(sdk_key, config, http_client = nil, retry_interval = DEFAULT_RETRY_INTERVAL)
        @sdk_key = sdk_key
        @config = config
        @events_uri = config.events_uri + "/bulk"
        @diagnostic_uri = config.events_uri + "/diagnostic"
        @logger = config.logger
        @retry_interval = retry_interval
        @http_client_pool = UnboundedPool.new(
          lambda { LaunchDarkly::Util.new_http_client(@config.events_uri, @config) },
          lambda { |client| client.close })
      end

      def stop
        @http_client_pool.dispose_all()
      end

      def send_event_data(event_data, description, is_diagnostic)
        uri = is_diagnostic ? @diagnostic_uri : @events_uri
        payload_id = is_diagnostic ? nil : SecureRandom.uuid
        begin
          http_client = @http_client_pool.acquire()
          response = nil
          2.times do |attempt|
            if attempt > 0
              @logger.warn { "[LDClient] Will retry posting events after #{@retry_interval} second" }
              sleep(@retry_interval)
            end
            begin
              @logger.debug { "[LDClient] sending #{description}: #{event_data}" }
              headers = {}
              headers["content-type"] = "application/json"
              Impl::Util.default_http_headers(@sdk_key, @config).each { |k, v| headers[k] = v }
              unless is_diagnostic
                headers["X-LaunchDarkly-Event-Schema"] = CURRENT_SCHEMA_VERSION.to_s
                headers["X-LaunchDarkly-Payload-ID"] = payload_id
              end
              response = http_client.request("POST", uri, {
                headers: headers,
                body: event_data,
              })
            rescue StandardError => exn
              @logger.warn { "[LDClient] Error sending events: #{exn.inspect}." }
              next
            end
            status = response.status.code
            # must fully read body for persistent connections
            body = response.to_s
            if status >= 200 && status < 300
              res_time = nil
              unless response.headers["date"].nil?
                begin
                  res_time = Time.httpdate(response.headers["date"])
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
          EventSenderResult.new(false, false, nil)
        ensure
          @http_client_pool.release(http_client)
        end
      end
    end
  end
end
