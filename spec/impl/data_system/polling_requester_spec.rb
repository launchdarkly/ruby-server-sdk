# frozen_string_literal: true

require "spec_helper"
require "http_util"
require "ldclient-rb/impl/data_system/polling"

module LaunchDarkly
  module Impl
    module DataSystem
      [HTTPPollingRequester, HTTPFDv1PollingRequester].each do |requester_class|
        RSpec.describe requester_class do
          it "abandons a connect attempt after the connect timeout" do
            socket_factory = HangingSocketFactory.new
            http_config = HttpConfigOptions.new(
              base_uri: "http://sdk.example.com",
              socket_factory: socket_factory,
              connect_timeout: 0.2
            )
            requester = requester_class.new("sdk_key", http_config, Config.new(logger: $null_log))

            fetch_thread = Thread.new { requester.fetch(nil) }
            begin
              # Without the connect timeout, the attempt blocks until the thread is killed.
              blocked = socket_factory.first_blocked_duration(3)
              expect(blocked).not_to be_nil
              expect(blocked).to be < 1
            ensure
              fetch_thread.kill unless fetch_thread.join(5)
            end
          end
        end
      end
    end
  end
end
