require 'ldclient-rb/impl/integrations/test_data_impl'

module LaunchDarkly
  module Integrations
    module TestData
      def self.factory
        LaunchDarkly::Impl::Integrations::TestDataImpl.new
      end
    end
  end
end
