require 'concurrent'
require 'ldclient-rb/impl/datasystem'
require 'ldclient-rb/impl/data_source'
require 'ldclient-rb/impl/data_store'
require 'ldclient-rb/impl/datasource/null_processor'
require 'ldclient-rb/impl/broadcaster'

module LaunchDarkly
  module Impl
    module DataSystem
      #
      # FDv1 wires the existing v1 data source and store behavior behind the
      # generic DataSystem surface.
      #
      # @private
      #
      class FDv1
        include LaunchDarkly::Impl::DataSystem

        #
        # Creates a new FDv1 data system.
        #
        # @param sdk_key [String] The SDK key
        # @param config [LaunchDarkly::Config] The SDK configuration
        #
        def initialize(sdk_key, config)
          @sdk_key = sdk_key
          @config = config
          @shared_executor = Concurrent::SingleThreadExecutor.new

          # Set up data store plumbing
          @data_store_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, @config.logger)
          @data_store_update_sink = LaunchDarkly::Impl::DataStore::UpdateSink.new(
            @data_store_broadcaster
          )

          # Wrap the data store with client wrapper (must be created before status provider)
          @store_wrapper = LaunchDarkly::Impl::FeatureStoreClientWrapper.new(
            @config.feature_store,
            @data_store_update_sink,
            @config.logger
          )

          # Create status provider with store wrapper
          @data_store_status_provider = LaunchDarkly::Impl::DataStore::StatusProvider.new(
            @store_wrapper,
            @data_store_update_sink
          )

          # Set up data source plumbing
          @data_source_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, @config.logger)
          @flag_change_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, @config.logger)
          @data_source_update_sink = LaunchDarkly::Impl::DataSource::UpdateSink.new(
            @store_wrapper,
            @data_source_broadcaster,
            @flag_change_broadcaster
          )
          @data_source_status_provider = LaunchDarkly::Impl::DataSource::StatusProvider.new(
            @data_source_broadcaster,
            @data_source_update_sink
          )

          # Ensure v1 processors can find the sink via config for status updates
          @config.data_source_update_sink = @data_source_update_sink

          # Update processor created in start(), because it needs the ready event
          @update_processor = nil

          # Diagnostic accumulator provided by client for streaming metrics
          @diagnostic_accumulator = nil
        end

        #
        # Starts the v1 update processor and returns immediately. The returned event
        # will be set by the processor upon first successful initialization or upon permanent failure.
        #
        # @return [Concurrent::Event] Event that will be set when initialization is complete
        #
        def start
          @update_processor = make_update_processor
          @update_processor.start
        end

        #
        # Halts the data system, stopping the update processor and shutting down the executor.
        #
        # @return [void]
        #
        def stop
          @update_processor&.stop
          @shared_executor.shutdown
        end

        #
        # Returns the feature store wrapper used by this data system.
        #
        # @return [LaunchDarkly::Impl::DataStore::ClientWrapper]
        #
        def store
          @store_wrapper
        end

        #
        # Sets the diagnostic accumulator for streaming initialization metrics.
        # This should be called before start() to ensure metrics are collected.
        #
        # @param diagnostic_accumulator [DiagnosticAccumulator] The diagnostic accumulator
        # @return [void]
        #
        def set_diagnostic_accumulator(diagnostic_accumulator)
          @diagnostic_accumulator = diagnostic_accumulator
        end

        #
        # Returns the data source status provider.
        #
        # @return [LaunchDarkly::Interfaces::DataSource::StatusProvider]
        #
        def data_source_status_provider
          @data_source_status_provider
        end

        #
        # Returns the data store status provider.
        #
        # @return [LaunchDarkly::Interfaces::DataStore::StatusProvider]
        #
        def data_store_status_provider
          @data_store_status_provider
        end

        #
        # Returns the broadcaster for flag change notifications.
        #
        # @return [LaunchDarkly::Impl::Broadcaster]
        #
        def flag_change_broadcaster
          @flag_change_broadcaster
        end

        #
        # Indicates what form of data is currently available.
        #
        # This is calculated dynamically based on current system state.
        #
        # @return [Symbol] One of DataAvailability constants
        #
        def data_availability
          return DataAvailability::DEFAULTS if @config.offline?

          unless @config.use_ldd?
            return DataAvailability::REFRESHED if @update_processor && @update_processor.initialized?
          end

          return DataAvailability::CACHED if @store_wrapper.initialized?

          DataAvailability::DEFAULTS
        end

        #
        # Indicates the ideal form of data attainable given the current configuration.
        #
        # @return [Symbol] One of DataAvailability constants
        #
        def target_availability
          return DataAvailability::DEFAULTS if @config.offline?
          return DataAvailability::CACHED if @config.use_ldd?

          DataAvailability::REFRESHED
        end

        #
        # Creates the appropriate update processor based on the configuration.
        #
        # @return [Object] The update processor
        #
        private def make_update_processor
          # Handle custom data source (factory or instance)
          if @config.data_source
            return @config.data_source unless @config.data_source.respond_to?(:call)

            # Factory - call with appropriate arity
            return @config.data_source.arity == 3 ?
              @config.data_source.call(@sdk_key, @config, @diagnostic_accumulator) :
              @config.data_source.call(@sdk_key, @config)
          end

          # Create default data source based on config
          return LaunchDarkly::Impl::DataSource::NullUpdateProcessor.new if @config.offline? || @config.use_ldd?

          if @config.stream?
            require 'ldclient-rb/stream'
            return LaunchDarkly::StreamProcessor.new(@sdk_key, @config, @diagnostic_accumulator)
          end

          # Polling processor
          require 'ldclient-rb/polling'
          requestor = LaunchDarkly::Requestor.new(@sdk_key, @config)
          LaunchDarkly::PollingProcessor.new(@config, requestor)
        end
      end
    end
  end
end

