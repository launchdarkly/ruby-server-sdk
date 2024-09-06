require "uri"
require "http"

module LaunchDarkly
  #
  # A Result is used to reflect the outcome of any operation.
  #
  # Results can either be considered a success or a failure.
  #
  # In the event of success, the Result will contain an option, nullable value to hold any success value back to the
  # calling function.
  #
  # If the operation fails, the Result will contain an error describing the value.
  #
  class Result
    #
    # Create a successful result with the provided value.
    #
    # @param value [Object, nil]
    # @return [Result]
    #
    def self.success(value)
      Result.new(value)
    end

    #
    # Create a failed result with the provided error description.
    #
    # @param error [String]
    # @param exception [Exception, nil]
    # @return [Result]
    #
    def self.fail(error, exception = nil)
      Result.new(nil, error, exception)
    end

    #
    # Was this result successful or did it encounter an error?
    #
    # @return [Boolean]
    #
    def success?
      @error.nil?
    end

    #
    # @return [Object, nil] The value returned from the operation if it was successful; nil otherwise.
    #
    attr_reader :value

    #
    # @return [String, nil] An error description of the failure; nil otherwise
    #
    attr_reader :error

    #
    # @return [Exception, nil] An optional exception which caused the failure
    #
    attr_reader :exception

    private def initialize(value, error = nil, exception = nil)
      @value = value
      @error = error
      @exception = exception
    end
  end

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
