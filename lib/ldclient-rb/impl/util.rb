require "uri"
require "http"

module LaunchDarkly
  module Impl
    module Util
      def self.bool?(aObject)
         [true,false].include? aObject
      end

      def self.current_time_millis
        (Time.now.to_f * 1000).to_i
      end

      def self.default_http_headers(sdk_key, config)
        ret = { "Authorization" => sdk_key, "User-Agent" => "RubyClient/" + LaunchDarkly::VERSION }

        ret["X-LaunchDarkly-Instance-Id"] = config.instance_id unless config.instance_id.nil?

        if config.wrapper_name
          ret["X-LaunchDarkly-Wrapper"] = config.wrapper_name +
            (config.wrapper_version ? "/" + config.wrapper_version : "")
        end

        app_value = application_header_value config.application
        ret["X-LaunchDarkly-Tags"] = app_value unless app_value.nil? || app_value.empty?

        ret
      end

      #
      # Generate an HTTP Header value containing the application meta information (@see #application).
      #
      # @return [String]
      #
      def self.application_header_value(application)
        parts = []
        unless  application[:id].empty?
          parts << "application-id/#{application[:id]}"
        end

        unless  application[:version].empty?
          parts << "application-version/#{application[:version]}"
        end

        parts.join(" ")
      end

      #
      # @param value [String]
      # @param name [Symbol]
      # @param logger [Logger]
      # @return [String]
      #
      def self.validate_application_value(value, name, logger)
        value = value.to_s

        return "" if value.empty?

        if value.length > 64
          logger.warn { "Value of application[#{name}] was longer than 64 characters and was discarded" }
          return ""
        end

        if /[^a-zA-Z0-9._-]/.match?(value)
          logger.warn { "Value of application[#{name}] contained invalid characters and was discarded" }
          return ""
        end

        value
      end

      #
      # @param app [Hash]
      # @param logger [Logger]
      # @return [Hash]
      #
      def self.validate_application_info(app, logger)
        {
          id: validate_application_value(app[:id], :id, logger),
          version: validate_application_value(app[:version], :version, logger),
        }
      end

      #
      # @param value [String, nil]
      # @param logger [Logger]
      # @return [String, nil]
      #
      def self.validate_payload_filter_key(value, logger)
        return nil if value.nil?
        return value if value.is_a?(String) && /^[a-zA-Z0-9][._\-a-zA-Z0-9]*$/.match?(value)

        logger.warn {
          "Invalid payload filter configured, full environment will be fetched. Ensure the filter key is not empty and was copied correctly from LaunchDarkly settings."
        }
        nil
      end

      #
      # Append the payload filter key query parameter to the provided URI.
      #
      # @param uri [String]
      # @param config [Config]
      # @return [String]
      #
      def self.add_payload_filter_key(uri, config)
        return uri if config.payload_filter_key.nil?

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

      #
      # Creates a new persistent HTTP client with the given configuration.
      #
      # @param http_config [LaunchDarkly::Impl::DataSystem::HttpConfigOptions] HTTP connection settings
      # @return [HTTP::Client]
      #
      def self.new_http_client(http_config)
        http_client_options = {}
        if http_config.socket_factory
          http_client_options["socket_class"] = http_config.socket_factory
        end
        proxy = URI.parse(http_config.base_uri).find_proxy
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
            read: http_config.read_timeout,
            connect: http_config.connect_timeout,
          })
          .persistent(http_config.base_uri)
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
        message = http_error_recoverable?(status) ? recoverable_message : "giving up permanently"
        "HTTP error #{status}#{desc} for #{context} - #{message}"
      end
    end
  end
end
