require 'ldclient-rb/impl/integrations/test_data_impl'

#
# A mechanism for providing dynamically updatable feature flag state in a simplified form to an SDK
# client in test scenarios.
# <p>
# Unlike {@link FileDataSource}, this mechanism does not use any external resources. It provides only
# the data that the application has put into it using the {@link #update(FlagBuilder)} method.
#
# <pre><code>
#     td = LaunchDarkly::Integrations::TestData.factory
#     td.update(td.flag("flag-key-1").variation_for_all_users(true))
#     config = LaunchDarkly::Config.new(data_source: td)
#     client = LaunchDarkly::LDClient.new('sdkKey', config)
#     # flags can be updated at any time:
#     td.update(td.flag("flag-key-2")
#                 .variation_for_user("some-user-key", true)
#                 .fallthrough_variation(false))
# </code></pre>
#
# The above example uses a simple boolean flag, but more complex configurations are possible using
# the methods of the {@link FlagBuilder} that is returned by {@link #flag(String)}. {@link FlagBuilder}
# supports many of the ways a flag can be configured on the LaunchDarkly dashboard, but does not
# currently support 1. rule operators other than "in" and "not in", or 2. percentage rollouts.
# <p>
# If the same {@code TestData} instance is used to configure multiple {@code LDClient} instances,
# any changes made to the data will propagate to all of the {@code LDClient}s.
#
module LaunchDarkly
  module Integrations
    module TestData
      # Creates a new instance of the test data source.
      # <p>
      # See {@link TestDataImpl} for details.
      #
      # @return a new configurable test data source
      #
      def self.factory
        LaunchDarkly::Impl::Integrations::TestDataImpl.new
      end
    end
  end
end
