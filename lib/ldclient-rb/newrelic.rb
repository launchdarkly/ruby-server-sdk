module LaunchDarkly

  class LDNewRelic
    begin
      require 'newrelic_rpm'
      NR_ENABLED = defined?(::NewRelic::Agent.add_custom_parameters)
    rescue Exception
      NR_ENABLED = false
    end

    def self.annotate_transaction(key, value)
      if NR_ENABLED
        ::NewRelic::Agent.add_custom_parameters({key.to_s => value.to_s})
      end
    end
  end


end