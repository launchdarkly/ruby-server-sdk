require "json"
require "net/http/persistent"
require "faraday/http_cache"

module LaunchDarkly

  class InvalidSDKKeyError < StandardError
  end

  class Requestor
    def initialize(sdk_key, config)
      @sdk_key = sdk_key
      @config = config
      @client = Faraday.new do |builder|
        builder.use :http_cache, store: @config.cache_store

        builder.adapter :net_http_persistent
      end
    end

    def request_all_flags()
      make_request("/sdk/latest-flags")
    end

    def request_flag(key)
      make_request("/sdk/latest-flags/" + key)
    end

    def request_all_segments()
      make_request("/sdk/latest-segments")
    end

    def request_segment(key)
      make_request("/sdk/latest-segments/" + key)
    end

    def request_all_data()
      make_request("/sdk/latest-all")
    end
    
    def make_request(path)
      uri = @config.base_uri + path
      res = @client.get (uri) do |req|
        req.headers["Authorization"] = @sdk_key
        req.headers["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
        req.options.timeout = @config.read_timeout
        req.options.open_timeout = @config.connect_timeout
        if @config.proxy
          req.options.proxy = Faraday::ProxyOptions.from @config.proxy
        end
      end

      @config.logger.debug("[LDClient] Got response from uri: #{uri}\n\tstatus code: #{res.status}\n\theaders: #{res.headers}\n\tbody: #{res.body}")

      if res.status == 401
        @config.logger.error("[LDClient] Invalid SDK key")
        raise InvalidSDKKeyError
      end

      if res.status == 404
        @config.logger.error("[LDClient] Resource not found")
        return nil
      end

      if res.status < 200 || res.status >= 300
        @config.logger.error("[LDClient] Unexpected status code #{res.status}")
        return nil
      end

      JSON.parse(res.body, symbolize_names: true)
    end

    private :make_request
  end
end
