# frozen_string_literal: true

module LaunchDarkly
  module Impl
    module DataSystem
      #
      # HttpConfigOptions contains HTTP connection configuration settings.
      # This class is created by data source builders and passed to v2 Requesters/DataSources.
      #
      class HttpConfigOptions
        # Generic HTTP defaults - base URIs live in the respective builders
        DEFAULT_READ_TIMEOUT = 10
        DEFAULT_CONNECT_TIMEOUT = 2

        attr_reader :base_uri, :socket_factory, :read_timeout, :connect_timeout

        #
        # @param base_uri [String] The base URI for HTTP requests
        # @param socket_factory [Object, nil] Optional socket factory for custom connections
        # @param read_timeout [Float, nil] Read timeout in seconds (defaults to DEFAULT_READ_TIMEOUT)
        # @param connect_timeout [Float, nil] Connect timeout in seconds (defaults to DEFAULT_CONNECT_TIMEOUT)
        #
        def initialize(base_uri:, socket_factory: nil, read_timeout: nil, connect_timeout: nil)
          @base_uri = base_uri
          @socket_factory = socket_factory
          @read_timeout = read_timeout || DEFAULT_READ_TIMEOUT
          @connect_timeout = connect_timeout || DEFAULT_CONNECT_TIMEOUT
        end
      end
    end
  end
end
