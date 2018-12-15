require "ldclient-rb/integrations/dynamodb"
require "ldclient-rb/integrations/redis"
require "ldclient-rb/integrations/util/store_wrapper"

module LaunchDarkly
  #
  # Tools for connecting the LaunchDarkly client to other software.
  #
  module Integrations
    #
    # Integration with [DynamoDB](https://aws.amazon.com/dynamodb/).
    #
    # @since 5.5.0
    #
    module DynamoDB
      # code is in ldclient-rb/impl/integrations/dynamodb_impl
    end

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
