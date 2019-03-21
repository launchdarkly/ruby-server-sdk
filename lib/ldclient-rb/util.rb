require "net/http"
require "uri"

module LaunchDarkly
  # @private
  module Util
    def self.new_http_client(uri_s, config)
      uri = URI(uri_s)
      client = Net::HTTP.new(uri.hostname, uri.port)
      client.use_ssl = true if uri.scheme == "https"
      client.open_timeout = config.connect_timeout
      client.read_timeout = config.read_timeout
      client
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
