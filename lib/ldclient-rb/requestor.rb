require "json"

module LaunchDarkly

  class Requestor
    def initialize(api_key, config)
      @api_key = api_key
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

    def make_request(path)
      res = @client.get (@config.base_uri + path) do |req|
        req.headers["Authorization"] = "api_key " + @api_key
        req.headers["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
        req.options.timeout = @config.read_timeout
        req.options.open_timeout = @config.connect_timeout
      end

      if res.status == 401
        @config.logger.error("[LDClient] Invalid API key")
        return nil
      end

      if res.status == 404
        @config.logger.error("[LDClient] Resource not found")
        return nil
      end

      if res.status / 100 != 2
        @config.logger.error("[LDClient] Unexpected status code #{res.status}")
        return nil
      end

      JSON.parse(res.body, symbolize_names: true)
    end

    private :make_request

  end

end