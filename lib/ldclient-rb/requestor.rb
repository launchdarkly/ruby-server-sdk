require "ldclient-rb/impl/model/serialization"

require "concurrent/atomics"
require "json"
require "uri"

module LaunchDarkly
  # @private
  class UnexpectedResponseError < StandardError
    def initialize(status)
      @status = status
      super("HTTP error #{status}")
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
      @client = Util.new_http_client(@config.base_uri, @config)
      @cache = @config.cache_store
    end

    def request_flag(key)
      request_single_item(FEATURES, "/sdk/latest-flags/" + key)
    end

    def request_segment(key)
      request_single_item(SEGMENTS, "/sdk/latest-segments/" + key)
    end

    def request_all_data()
      all_data = JSON.parse(make_request("/sdk/latest-all"), symbolize_names: true)
      Impl::Model.make_all_store_data(all_data)
    end
    
    def stop
      begin
        @client.finish
      rescue
      end
    end

    private

    def request_single_item(kind, path)
      Impl::Model.deserialize(kind, make_request(path))
    end

    def make_request(path)
      @client.start if !@client.started?
      uri = URI(@config.base_uri + path)
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = @sdk_key
      req["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
      req["Connection"] = "keep-alive"
      cached = @cache.read(uri)
      if !cached.nil?
        req["If-None-Match"] = cached.etag
      end
      res = @client.request(req)
      status = res.code.to_i
      @config.logger.debug { "[LDClient] Got response from uri: #{uri}\n\tstatus code: #{status}\n\theaders: #{res.to_hash}\n\tbody: #{res.body}" }

      if status == 304 && !cached.nil?
        body = cached.body
      else
        @cache.delete(uri)
        if status < 200 || status >= 300
          raise UnexpectedResponseError.new(status)
        end
        body = fix_encoding(res.body, res["content-type"])
        etag = res["etag"]
        @cache.write(uri, CacheEntry.new(etag, body)) if !etag.nil?
      end
      body
    end

    def fix_encoding(body, content_type)
      return body if content_type.nil?
      media_type, charset = parse_content_type(content_type)
      return body if charset.nil?
      body.force_encoding(Encoding::find(charset)).encode(Encoding::UTF_8)
    end

    def parse_content_type(value)
      return [nil, nil] if value.nil? || value == ''
      parts = value.split(/; */)
      return [value, nil] if parts.count < 2
      charset = nil
      parts.each do |part|
        fields = part.split('=')
        if fields.count >= 2 && fields[0] == 'charset'
          charset = fields[1]
          break
        end
      end
      return [parts[0], charset]
    end
  end
end
