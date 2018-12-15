require "ldclient-rb/integrations/redis"

module LaunchDarkly
  #
  # Tools for connecting the LaunchDarkly client to other software.
  #
  module Integrations
    #
    # Integration with [Redis](https://redis.io/).
    #
    # @since 5.5.0
    #
    module Redis
      # code is in ldclient-rb/impl/integrations/redis_impl
    end

    #
    # Support code that may be helpful in creating integrations.
    #
    # @since 5.5.0
    #
    module Util
      # code is in ldclient-rb/integrations/util/
    end
  end
end
