require "uri"
require "http"

module LaunchDarkly
  # @private
  module Util
    def self.stringify_attrs(hash, attrs)
      return hash if hash.nil?
      ret = hash
      changed = false
      attrs.each do |attr|
        value = hash[attr]
        if !value.nil? && !value.is_a?(String)
          ret = hash.clone if !changed
          ret[attr] = value.to_s
          changed = true
        end
      end
      ret
    end

    def self.new_http_client(uri_s, config)
      http_client_options = {}

      uri = URI(uri_s)
      if config.using_proxy?
        if uri.scheme == 'http' && ENV["http_proxy"] || ENV["HTTP_PROXY"]
          proxy_uri = URI(ENV["http_proxy"] || ENV["HTTP_PROXY"])
        elsif uri.scheme == 'https' && ENV["https_proxy"] || ENV["HTTPS_PROXY"]
          proxy_uri = URI(ENV["https_proxy"] || ENV["HTTPS_PROXY"])
        end

        if proxy_uri
          # TODO: respect no_proxy settings
          http_client_options["proxy"] = {
            :proxy_address => proxy_uri.host,
            :proxy_port => proxy_uri.port
          }
        end
      end

      if config.socket_factory
        http_client_options["socket_class"] = config.socket_factory
      end
      return HTTP::Client.new(http_client_options)
        .timeout({
          read: config.read_timeout,
          connect: config.connect_timeout
        })
        .persistent(uri)
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
