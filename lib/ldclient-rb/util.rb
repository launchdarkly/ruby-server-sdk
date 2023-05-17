require "uri"
require "http"

module LaunchDarkly
  # @private
  module Util
    #
    # Append the payload filter key query parameter to the provided URI.
    #
    # @param uri [String]
    # @param config [Config]
    # @return [String]
    #
    def self.add_payload_filter_key(uri, config)
      return uri if config.payload_filter_key.nil?

      unless config.payload_filter_key.is_a?(String) && !config.payload_filter_key.empty?
        config.logger.warn { "[LDClient] Filter key must be a non-empty string. No filtering will be applied." }
        return uri
      end

      begin
        parsed = URI.parse(uri)
        new_query_params = URI.decode_www_form(String(parsed.query)) << ["filter", config.payload_filter_key]
        parsed.query = URI.encode_www_form(new_query_params)
        parsed.to_s
      rescue URI::InvalidURIError
        config.logger.warn { "[LDClient] URI could not be parsed. No filtering will be applied." }
        uri
      end
    end

    def self.new_http_client(uri_s, config)
      http_client_options = {}
      if config.socket_factory
        http_client_options["socket_class"] = config.socket_factory
      end
      proxy = URI.parse(uri_s).find_proxy
      unless proxy.nil?
        http_client_options["proxy"] = {
          proxy_address: proxy.host,
          proxy_port: proxy.port,
          proxy_username: proxy.user,
          proxy_password: proxy.password,
        }
      end
      HTTP::Client.new(http_client_options)
        .timeout({
          read: config.read_timeout,
          connect: config.connect_timeout,
        })
        .persistent(uri_s)
    end

    def self.log_exception(logger, message, exc)
      logger.error { "[LDClient] #{message}: #{exc.inspect}" }
      logger.debug { "[LDClient] Exception trace: #{exc.backtrace}" }
    end

    def self.http_error_recoverable?(status)
      if status >= 400 && status < 500
        status == 400 || status == 408 || status == 429
      else
        true
      end
    end

    def self.http_error_message(status, context, recoverable_message)
      desc = (status == 401 || status == 403) ? " (invalid SDK key)" : ""
      message = Util.http_error_recoverable?(status) ? recoverable_message : "giving up permanently"
      "HTTP error #{status}#{desc} for #{context} - #{message}"
    end
  end
end
