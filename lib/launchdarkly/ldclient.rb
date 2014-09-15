require 'faraday/http_cache'
require 'json'

module Launchdarkly
  class LdClient
    
    def initialize(api_key, config = Config.default)
      store = ThreadSafeMemoryStore.new
      @api_key = api_key
      @client = Faraday.new do |builder|
        builder.use :http_cache, store: store

        builder.adapter Faraday.default_adapter
      end
    end

    def get_flag(key, user, default=false)

    end


  end
end