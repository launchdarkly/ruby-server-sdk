# frozen_string_literal: true

require "ldclient-rb/impl/data_system/http_config_options"

module LaunchDarkly
  module DataSystem
    #
    # Common HTTP configuration methods shared by all data source builders.
    #
    # This module is included by {PollingDataSourceBuilder},
    # {FDv1PollingDataSourceBuilder}, and {StreamingDataSourceBuilder} to provide
    # a consistent set of HTTP connection settings.
    #
    # Each builder that includes this module must define a +DEFAULT_BASE_URI+ constant
    # which is used as the fallback when {#base_uri} has not been called.
    #
    module DataSourceBuilderCommon
      #
      # Sets the base URI for HTTP requests.
      #
      # Use this to point the SDK at a Relay Proxy instance or any other URI
      # that implements the corresponding LaunchDarkly API.
      #
      # @param uri [String] The base URI (e.g. "https://relay.example.com")
      # @return [self] the builder, for chaining
      #
      def base_uri(uri)
        @base_uri = uri
        self
      end

      #
      # Sets a custom socket factory for HTTP connections.
      #
      # @param factory [#open] A socket factory that responds to +open+
      # @return [self] the builder, for chaining
      #
      def socket_factory(factory)
        @socket_factory = factory
        self
      end

      #
      # Sets the read timeout for HTTP connections.
      #
      # @param timeout [Float] Timeout in seconds
      # @return [self] the builder, for chaining
      #
      def read_timeout(timeout)
        @read_timeout = timeout
        self
      end

      #
      # Sets the connect timeout for HTTP connections.
      #
      # @param timeout [Float] Timeout in seconds
      # @return [self] the builder, for chaining
      #
      def connect_timeout(timeout)
        @connect_timeout = timeout
        self
      end

      #
      # Builds an HttpConfigOptions instance from the current builder settings.
      # Uses +self.class::DEFAULT_BASE_URI+ if {#base_uri} was not explicitly set.
      # Read/connect timeouts default to HttpConfigOptions defaults if not set.
      #
      # @return [LaunchDarkly::Impl::DataSystem::HttpConfigOptions]
      #
      private def build_http_config
        LaunchDarkly::Impl::DataSystem::HttpConfigOptions.new(
          base_uri: (@base_uri || self.class::DEFAULT_BASE_URI).chomp("/"),
          socket_factory: @socket_factory,
          read_timeout: @read_timeout,
          connect_timeout: @connect_timeout
        )
      end
    end
  end

end
