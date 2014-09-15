module Launchdarkly
  class Config
    def initialize(base_uri)
      @base_uri = base_uri
    end

    def base_uri
      @base_uri
    end

    def self.default
      Config.new('https://app.launchdarkly.com')
    end
  end
end