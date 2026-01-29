# frozen_string_literal: true

require "ldclient-rb/impl/data_system/http_config_options"

module LaunchDarkly
  module Impl
    module DataSystem
      #
      # DataSourceBuilderCommon is a mixin that provides common HTTP configuration
      # setters for data source builders (polling and streaming).
      #
      # Each builder that includes this module must define a DEFAULT_BASE_URI constant.
      #
      module DataSourceBuilderCommon
        #
        # Sets the base URI for HTTP requests.
        #
        # @param uri [String]
        # @return [self]
        #
        def base_uri(uri)
          @base_uri = uri
          self
        end

        #
        # Sets a custom socket factory for HTTP connections.
        #
        # @param factory [Object]
        # @return [self]
        #
        def socket_factory(factory)
          @socket_factory = factory
          self
        end

        #
        # Sets the read timeout for HTTP connections.
        #
        # @param timeout [Float] Timeout in seconds
        # @return [self]
        #
        def read_timeout(timeout)
          @read_timeout = timeout
          self
        end

        #
        # Sets the connect timeout for HTTP connections.
        #
        # @param timeout [Float] Timeout in seconds
        # @return [self]
        #
        def connect_timeout(timeout)
          @connect_timeout = timeout
          self
        end

        #
        # Builds an HttpConfigOptions instance from the current builder settings.
        # Uses self.class::DEFAULT_BASE_URI if base_uri was not explicitly set.
        # Read/connect timeouts default to HttpConfigOptions defaults if not set.
        #
        # @return [HttpConfigOptions]
        #
        private def build_http_config
          HttpConfigOptions.new(
            base_uri: (@base_uri || self.class::DEFAULT_BASE_URI).chomp("/"),
            socket_factory: @socket_factory,
            read_timeout: @read_timeout,
            connect_timeout: @connect_timeout
          )
        end
      end
    end
  end
end
