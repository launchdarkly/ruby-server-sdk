require "concurrent/atomics"
require "json"
require "net/http/persistent"

module LaunchDarkly
  # @private
  class UnexpectedResponseError < StandardError
    def initialize(status)
      @status = status
    end

    def status
      @status
    end
  end

  # @private
  class Requestor
    CacheEntry = Struct.new(:etag, :body)

    def initialize(sdk_key, config)
      @sdk_key = sdk_key
      @config = config
      @client = Net::HTTP::Persistent.new
      @client.open_timeout = @config.connect_timeout
      @client.read_timeout = @config.read_timeout
      @cache = @config.cache_store
    end

    def request_flag(key)
      make_request("/sdk/latest-flags/" + key)
    end

    def request_segment(key)
      make_request("/sdk/latest-segments/" + key)
    end

    def request_all_data()
      make_request("/sdk/latest-all")
    end
    
    def make_request(path)
      uri = URI(@config.base_uri + path)
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = @sdk_key
      req["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
      cached = @cache.read(uri)
      if !cached.nil?
        req["If-None-Match"] = cached.etag
      end
        # if @config.proxy
        #   req.options.proxy = Faraday::ProxyOptions.from @config.proxy
        # end

      res = @client.request(uri, req)
      status = res.code.to_i
      @config.logger.debug { "[LDClient] Got response from uri: #{uri}\n\tstatus code: #{status}\n\theaders: #{res.to_hash}\n\tbody: #{res.body}" }

      if status == 304 && !cached.nil?
        body = cached.body
      else
        @cache.delete(uri)
        if status < 200 || status >= 300
          raise UnexpectedResponseError.new(status)
        end
        body = res.body
        etag = res["etag"]
        @cache.write(uri, CacheEntry.new(etag, body)) if !etag.nil?
      end
      JSON.parse(body, symbolize_names: true)
    end

    def stop
      @client.shutdown
    end

    private :make_request
  end
end
