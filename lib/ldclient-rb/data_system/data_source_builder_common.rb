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
    # A setting that the builder does not set comes from the SDK configuration. The
    # base URI comes from {LaunchDarkly::Config#base_uri} for the polling builders and
    # from {LaunchDarkly::Config#stream_uri} for the streaming builder. The socket factory
    # and the timeouts come from {LaunchDarkly::Config#socket_factory},
    # {LaunchDarkly::Config#read_timeout} and {LaunchDarkly::Config#connect_timeout}.
    #
    # Each builder that includes this module must define a private +config_base_uri+
    # method that returns the base URI from the SDK configuration.
    #
    module DataSourceBuilderCommon
      #
      # Sets the base URI for HTTP requests.
      #
      # Use this to point the SDK at a Relay Proxy instance or any other URI
      # that implements the corresponding LaunchDarkly API. This value overrides
      # the base URI in the SDK configuration.
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
      # This value overrides {LaunchDarkly::Config#socket_factory}.
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
      # This value overrides {LaunchDarkly::Config#read_timeout}.
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
      # This value overrides {LaunchDarkly::Config#connect_timeout}.
      #
      # @param timeout [Float] Timeout in seconds
      # @return [self] the builder, for chaining
      #
      def connect_timeout(timeout)
        @connect_timeout = timeout
        self
      end

      #
      # Builds an HttpConfigOptions instance from the builder settings. A setting
      # that the builder does not set comes from the SDK configuration.
      #
      # @param config [LaunchDarkly::Config] the SDK configuration
      # @return [LaunchDarkly::Impl::DataSystem::HttpConfigOptions]
      #
      private def build_http_config(config)
        LaunchDarkly::Impl::DataSystem::HttpConfigOptions.new(
          base_uri: (@base_uri || config_base_uri(config)).chomp("/"),
          socket_factory: @socket_factory || config.socket_factory,
          read_timeout: @read_timeout || config.read_timeout,
          connect_timeout: @connect_timeout || config.connect_timeout
        )
      end
    end
  end
end
