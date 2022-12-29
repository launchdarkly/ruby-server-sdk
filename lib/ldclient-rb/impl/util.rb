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
    end
  end
end
