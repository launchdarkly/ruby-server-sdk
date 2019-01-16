require "ldclient-rb/integrations/consul"
require "ldclient-rb/integrations/dynamodb"
require "ldclient-rb/integrations/redis"
require "ldclient-rb/integrations/util/store_wrapper"

module LaunchDarkly
  #
  # Tools for connecting the LaunchDarkly client to other software.
  #
  module Integrations
    #
    # Integration with [Consul](https://www.consul.io/).
    #
    # Note that in order to use this integration, you must first install the gem `diplomat`.
    #
    # @since 5.5.0
    #
    module Consul
      # code is in ldclient-rb/impl/integrations/consul_impl
    end
    
    #
    # Integration with [DynamoDB](https://aws.amazon.com/dynamodb/).
    #
    # Note that in order to use this integration, you must first install one of the AWS SDK gems: either
    # `aws-sdk-dynamodb`, or the full `aws-sdk`.
    #
    # @since 5.5.0
    #
    module DynamoDB
      # code is in ldclient-rb/impl/integrations/dynamodb_impl
    end

    #
    # Integration with [Redis](https://redis.io/).
    #
    # Note that in order to use this integration, you must first install the `redis` and `connection-pool`
    # gems.
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
