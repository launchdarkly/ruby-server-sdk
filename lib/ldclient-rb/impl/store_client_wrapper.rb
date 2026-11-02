require "concurrent"
require "ldclient-rb/interfaces"
require "ldclient-rb/impl/store_data_set_sorter"

module LaunchDarkly
  module Impl
    #
    # Provides additional behavior that the client requires before or after feature store operations.
    # This just means sorting the data set for init() and dealing with data store status listeners.
    #
    class FeatureStoreClientWrapper
      include Interfaces::FeatureStore

      def initialize(store, store_update_sink, logger)
        # @type [LaunchDarkly::Interfaces::FeatureStore]
        @store = store

        @monitoring_enabled = @store.monitoring_enabled?

        # @type [LaunchDarkly::Impl::DataStore::UpdateSink]
        @store_update_sink = store_update_sink
        @logger = logger

        @mutex = Mutex.new # Covers the following variables
        @last_available = true
        @stopped = false
        # @type [LaunchDarkly::Impl::RepeatingTask, nil]
        @poller = nil
      end

      def init(all_data)
        wrapper { @store.init(FeatureStoreDataSetSorter.sort_all_collections(all_data)) }
      end

      def get(kind, key)
        wrapper { @store.get(kind, key) }
      end

      def all(kind)
        wrapper { @store.all(kind) }
      end

      def upsert(kind, item)
        wrapper { @store.upsert(kind, item) }
      end

      def delete(kind, key, version)
        wrapper { @store.delete(kind, key, version) }
      end

      def initialized?
        @store.initialized?
      end

      def stop
        @store.stop

        poller = @mutex.synchronize do
          @stopped = true
          task = @poller
          @poller = nil
          task
        end
        poller&.stop
      end

      def monitoring_enabled?
        @monitoring_enabled
      end

      def available?
        @store.available?
      end

      private def wrapper()
        begin
          yield
        rescue => e
          update_availability(false) if @monitoring_enabled
          raise
        end
      end

      private def update_availability(available)
        @mutex.synchronize do
          return if available == @last_available
          @last_available = available
        end

        status = LaunchDarkly::Interfaces::DataStore::Status.new(available, false)

        @logger.warn("Persistent store is available again") if available

        @store_update_sink.update_status(status)

        if available
          poller = @mutex.synchronize do
            task = @poller
            @poller = nil
            task
          end
          poller&.stop

          return
        end

        @logger.warn("Detected persistent store unavailability; updates will be cached until it recovers.")

        task = Impl::RepeatingTask.new(0.5, 0, -> { self.check_availability }, @logger, 'LD/StoreWrapper#check_availability')

        @mutex.synchronize do
          # A read can fail after stop, and a poller started then would never be stopped.
          next if @stopped

          @poller = task
          @poller.start
        end
      end

      private def check_availability
        begin
          update_availability(true) if @store.available?
        rescue => e
          @logger.error("Unexpected error from data store status function: #{e}")
        end
      end
    end
  end
end
