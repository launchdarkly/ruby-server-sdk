# frozen_string_literal: true

require "concurrent"
require "ldclient-rb/interfaces"
require "ldclient-rb/impl/store_data_set_sorter"
require "ldclient-rb/impl/repeating_task"

module LaunchDarkly
  module Impl
    module DataStore
      #
      # Provides additional behavior that the client requires before or after feature store operations.
      # Currently this just means sorting the data set for init() and dealing with data store status listeners.
      #
      class FeatureStoreClientWrapperV2
        include LaunchDarkly::Interfaces::FeatureStore

        #
        # Initialize the wrapper.
        #
        # @param store [LaunchDarkly::Interfaces::FeatureStore] The underlying feature store
        # @param store_update_sink [LaunchDarkly::Impl::DataStore::StatusProviderV2] The status provider for updates
        # @param logger [Logger] The logger instance
        #
        def initialize(store, store_update_sink, logger)
          @store = store
          @store_update_sink = store_update_sink
          @logger = logger
          @monitoring_enabled = store_supports_monitoring?

          # Thread synchronization
          @mutex = Mutex.new
          @last_available = true
          @poller = nil
        end

        # (see LaunchDarkly::Interfaces::FeatureStore#init)
        def init(all_data)
          wrapper { @store.init(FeatureStoreDataSetSorter.sort_all_collections(all_data)) }
        end

        # (see LaunchDarkly::Interfaces::FeatureStore#get)
        def get(kind, key)
          wrapper { @store.get(kind, key) }
        end

        # (see LaunchDarkly::Interfaces::FeatureStore#all)
        def all(kind)
          wrapper { @store.all(kind) }
        end

        # (see LaunchDarkly::Interfaces::FeatureStore#delete)
        def delete(kind, key, version)
          wrapper { @store.delete(kind, key, version) }
        end

        # (see LaunchDarkly::Interfaces::FeatureStore#upsert)
        def upsert(kind, item)
          wrapper { @store.upsert(kind, item) }
        end

        # (see LaunchDarkly::Interfaces::FeatureStore#initialized?)
        def initialized?
          @store.initialized?
        end

        #
        # Returns whether monitoring is enabled.
        #
        # @return [Boolean]
        #
        def monitoring_enabled?
          @monitoring_enabled
        end

        #
        # Wraps store operations with exception handling and availability tracking.
        #
        # @yield The block to execute
        # @return [Object] The result of the block
        #
        private def wrapper
          begin
            yield
          rescue StandardError
            update_availability(false) if @monitoring_enabled
            raise
          end
        end

        #
        # Updates the availability status of the store.
        #
        # @param available [Boolean] Whether the store is available
        # @return [void]
        #
        private def update_availability(available)
          state_changed = false
          poller_to_stop = nil

          @mutex.synchronize do
            return if available == @last_available

            state_changed = true
            @last_available = available

            if available
              poller_to_stop = @poller
              @poller = nil
            elsif @poller.nil?
              task = LaunchDarkly::Impl::RepeatingTask.new(0.5, 0, method(:check_availability), @logger, "LDClient/DataStoreWrapperV2#check-availability")
              @poller = task
              @poller.start
            end
          end

          return unless state_changed

          if available
            @logger.warn { "[LDClient] Persistent store is available again" }
          else
            @logger.warn { "[LDClient] Detected persistent store unavailability; updates will be cached until it recovers" }
          end

          status = LaunchDarkly::Interfaces::DataStore::Status.new(available, true)
          @store_update_sink.update_status(status)

          poller_to_stop.stop if poller_to_stop
        end

        #
        # Checks if the store is available.
        #
        # @return [void]
        #
        private def check_availability
          begin
            update_availability(true) if @store.available?
          rescue => e
            @logger.error { "[LDClient] Unexpected error from data store status function: #{e.message}" }
          end
        end

        #
        # Determines whether the wrapped store can support enabling monitoring.
        #
        # The wrapped store must provide a monitoring_enabled? method, which must
        # be true. But this alone is not sufficient.
        #
        # Because this class wraps all interactions with a provided store, it can
        # technically "monitor" any store. However, monitoring also requires that
        # we notify listeners when the store is available again.
        #
        # We determine this by checking the store's available? method, so this
        # is also a requirement for monitoring support.
        #
        # @return [Boolean]
        #
        private def store_supports_monitoring?
          return false unless @store.respond_to?(:monitoring_enabled?)
          return false unless @store.respond_to?(:available?)

          @store.monitoring_enabled?
        end
      end
    end
  end
end
