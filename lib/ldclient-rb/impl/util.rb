module LaunchDarkly
  module Impl
    module Util
      def self.bool?(aObject)
         [true,false].include? aObject
      end

      def self.current_time_millis
        (Time.now.to_f * 1000).to_i
      end

      def self.default_http_headers(sdk_key, config)
        ret = { "Authorization" => sdk_key, "User-Agent" => "RubyClient/" + LaunchDarkly::VERSION }
        if config.wrapper_name
          ret["X-LaunchDarkly-Wrapper"] = config.wrapper_name +
            (config.wrapper_version ? "/" + config.wrapper_version : "")
        end
        ret
      end
    end
  end
end
