require 'logger'

module LaunchDarkly
  class Config
    def initialize(opts = {})
      @logger = opts[:logger] || Config.default_logger
      @base_uri = opts[:base_uri] || Config.default_base_uri
    end

    def base_uri
      @base_uri
    end

    def logger
      @logger
    end

    def self.default
      Config.new({:base_uri => Config.default_base_uri, :logger => Config.default_logger})
    end

    def self.default_base_uri
      "https://app.launchdarkly.com"
    end

    def self.default_logger
      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : ::Logger.new($stdout)
    end
  end
end