module LaunchDarkly

  #
  # Module to manage user flag settings
  #
  module Settings
    #
    # Specifically enable or disable a feature flag for a user based
    # on their key.
    #
    # @param user_key [String] the key of the user
    # @param flag_key [String] the unique feature key for the feature flag, as shown
    #   on the LaunchDarkly dashboard
    # @param setting [Boolean] the new setting, one of:
    #    true: the feature is always on
    #    false: the feature is never on
    #    nil: remove the setting (assign user per defined rules)
    def update_user_flag_setting(user_key, flag_key, setting=nil)
      unless user_key
        @config.logger.error("[LDClient] Must specify user")
        return
      end      

      user_setting_endpoint = "#{@config.base_uri}/api/users/#{user_key}/features/#{flag_key}"
      @config.logger.debug "[LDClient] Setting: #{user_setting_endpoint}"
      res = log_timings('update_user_flag_setting') do
        @client.put(user_setting_endpoint) do |req|
          req.headers['Authorization'] = "api_key #{@api_key}"
          req.headers['User-Agent'] = "RubyClient/#{LaunchDarkly::VERSION}"
          req.headers['Content-Type'] = 'application/json'
          req.body = {setting: setting}.to_json
          req.options.timeout = @config.read_timeout
          req.options.open_timeout = @config.connect_timeout
        end
      end

      unless res.success?
        @config.logger.error("[LDClient] Failed to change setting, status: #{res.status}")
        return nil
      end
    end
  end
end