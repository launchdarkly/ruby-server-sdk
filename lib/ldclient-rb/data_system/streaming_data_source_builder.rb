# frozen_string_literal: true

require "ldclient-rb/data_system/data_source_builder_common"

module LaunchDarkly
  module DataSystem
    #
    # Builder for a streaming data source that uses Server-Sent Events (SSE)
    # to receive real-time updates from LaunchDarkly's Flag Delivery services.
    #
    # This builder can be used with {ConfigBuilder#synchronizers} to create
    # custom data system configurations. Streaming provides the lowest latency
    # for flag updates compared to polling.
    #
    # == Example
    #
    #   streaming = LaunchDarkly::DataSystem.streaming_ds_builder
    #     .initial_reconnect_delay(2)
    #     .base_uri("https://custom-stream.example.com")
    #
    #   data_system = LaunchDarkly::DataSystem.custom
    #     .synchronizers([streaming])
    #
    # @see DataSystem.streaming_ds_builder
    #
    class StreamingDataSourceBuilder
      include LaunchDarkly::DataSystem::DataSourceBuilderCommon

      # @return [String] The default base URI for streaming connections
      DEFAULT_BASE_URI = "https://stream.launchdarkly.com"

      # @return [Float] The default initial reconnect delay in seconds
      DEFAULT_INITIAL_RECONNECT_DELAY = 1

      def initialize
        # No initialization needed - defaults applied in build via nil-check
      end

      #
      # Sets the initial delay before reconnecting after a stream connection error.
      #
      # The SDK uses an exponential backoff strategy starting from this delay.
      # The default is {DEFAULT_INITIAL_RECONNECT_DELAY} second.
      #
      # @param delay [Float] Delay in seconds
      # @return [StreamingDataSourceBuilder] self for chaining
      #
      def initial_reconnect_delay(delay)
        @initial_reconnect_delay = delay
        self
      end

      #
      # Builds the streaming data source with the configured parameters.
      #
      # This method is called internally by the SDK. You do not need to call it
      # directly; instead, pass the builder to {ConfigBuilder#synchronizers}.
      #
      # @param sdk_key [String] The SDK key
      # @param config [LaunchDarkly::Config] The SDK configuration
      # @return [LaunchDarkly::Impl::DataSystem::StreamingDataSource]
      #
      def build(sdk_key, config)
        http_opts = build_http_config
        LaunchDarkly::Impl::DataSystem::StreamingDataSource.new(
          sdk_key, http_opts,
          @initial_reconnect_delay || DEFAULT_INITIAL_RECONNECT_DELAY,
          config
        )
      end
    end
  end
end
