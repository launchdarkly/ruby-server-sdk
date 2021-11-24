require "ldclient-rb/impl/big_segments"

require "spec_helper"

module LaunchDarkly
  module LDClientSpecBase
    def sdk_key
      "sdk-key"
    end

    def user
      {
        key: "userkey",
        email: "test@example.com",
        name: "Bob"
      }
    end

    def null_logger
      double().as_null_object
    end

    def null_data_source
      NullUpdateProcessor.new
    end

    def base_config
      Config.new(send_events: false, data_source: null_data_source, logger: null_logger)
    end

    def with_client(config)
      client = LDClient.new(sdk_key, config)
      begin
        yield client
      ensure
        client.close
      end
    end
  end

  RSpec.configure { |c| c.include LDClientSpecBase, :ldclient_spec_base => true }
end
