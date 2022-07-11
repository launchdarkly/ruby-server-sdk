require "ldclient-rb/impl/model/serialization"

require "concurrent/atomics"
require "json"
require "uri"
require "http"

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
      @http_client = LaunchDarkly::Util.new_http_client(config.base_uri, config)
      @cache = @config.cache_store
    end

    def request_all_data()
      all_data = JSON.parse(make_request("/sdk/latest-all"), symbolize_names: true)
      Impl::Model.make_all_store_data(all_data)
    end

    def stop
      begin
        @http_client.close
      rescue
      end
    end

    private

    def request_single_item(kind, path)
      Impl::Model.deserialize(kind, make_request(path))
    end

    def make_request(path)
      uri = URI(@config.base_uri + path)
      headers = {}
      Impl::Util.default_http_headers(@sdk_key, @config).each { |k, v| headers[k] = v }
      headers["Connection"] = "keep-alive"
      cached = @cache.read(uri)
      if !cached.nil?
        headers["If-None-Match"] = cached.etag
      end
      response = @http_client.request("GET", uri, {
        headers: headers,
      })
      status = response.status.code
      # must fully read body for persistent connections
      body = response.to_s
      @config.logger.debug { "[LDClient] Got response from uri: #{uri}\n\tstatus code: #{status}\n\theaders: #{response.headers.to_h}\n\tbody: #{body}" }
      if status == 304 && !cached.nil?
        body = cached.body
      else
        @cache.delete(uri)
        if status < 200 || status >= 300
          raise UnexpectedResponseError.new(status)
        end
        body = fix_encoding(body, response.headers["content-type"])
        etag = response.headers["etag"]
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
