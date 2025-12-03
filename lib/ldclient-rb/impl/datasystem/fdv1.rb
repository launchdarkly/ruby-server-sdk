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
      # @see DataSystem
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

          # Update processor created in start()
          @update_processor = nil

          # Diagnostic accumulator provided by client for streaming metrics
          @diagnostic_accumulator = nil
        end

        # (see DataSystem#start)
        def start
          @update_processor ||= make_update_processor
          @update_processor.start
        end

        # (see DataSystem#stop)
        def stop
          @update_processor&.stop
          @shared_executor.shutdown
        end

        # (see DataSystem#store)
        def store
          @store_wrapper
        end

        # (see DataSystem#set_diagnostic_accumulator)
        def set_diagnostic_accumulator(diagnostic_accumulator)
          @diagnostic_accumulator = diagnostic_accumulator
        end

        # (see DataSystem#data_source_status_provider)
        def data_source_status_provider
          @data_source_status_provider
        end

        # (see DataSystem#data_store_status_provider)
        def data_store_status_provider
          @data_store_status_provider
        end

        # (see DataSystem#flag_change_broadcaster)
        def flag_change_broadcaster
          @flag_change_broadcaster
        end

        #
        # (see DataSystem#data_availability)
        #
        # In LDD mode, always returns CACHED for backwards compatibility,
        # even if the store is empty.
        #
        def data_availability
          return DataAvailability::DEFAULTS if @config.offline?

          # In LDD mode, always return CACHED for backwards compatibility.
          # Even though the store might be empty (technically DEFAULTS), we maintain
          # the existing behavior where LDD mode is assumed to have data available
          # from the external daemon, regardless of the store's initialization state.
          return DataAvailability::CACHED if @config.use_ldd?

          return DataAvailability::REFRESHED if @update_processor && @update_processor.initialized?
          return DataAvailability::CACHED if @store_wrapper.initialized?

          DataAvailability::DEFAULTS
        end

        # (see DataSystem#target_availability)
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

