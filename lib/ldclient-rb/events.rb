module LaunchDarkly

  class EventProcessor
    def initialize(api_key, config)
      @api_key = api_key
      @config = config
      @client = Faraday.new do |builder|
        builder.use :http_cache, store: @config.cache_store
        builder.adapter :net_http_persistent
      end
    end
  end

end