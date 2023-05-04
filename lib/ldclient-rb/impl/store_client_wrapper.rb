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

        @monitoring_enabled = does_store_support_monitoring?

        # @type [LaunchDarkly::Impl::DataStore::UpdateSink]
        @store_update_sink = store_update_sink
        @logger = logger

        @mutex = Mutex.new # Covers the following variables
        @last_available = true
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
        @mutex.synchronize do
          return if @poller.nil?

          @poller.stop
          @poller = nil
        end
      end

      def monitoring_enabled?
        @monitoring_enabled
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
          @mutex.synchronize do
            return if @poller.nil?

            @poller.stop
            @poller = nil
          end

          return
        end

        @logger.warn("Detected persistent store unavailability; updates will be cached until it recovers.")

        task = Impl::RepeatingTask.new(0.5, 0, -> { self.check_availability }, @logger)

        @mutex.synchronize do
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

      # This methods determines whether the wrapped store can support enabling monitoring.
      #
      # The wrapped store must provide a monitoring_enabled method, which must
      # be true. But this alone is not sufficient.
      #
      # Because this class wraps all interactions with a provided store, it can
      # technically "monitor" any store. However, monitoring also requires that
      # we notify listeners when the store is available again.
      #
      # We determine this by checking the store's `available?` method, so this
      # is also a requirement for monitoring support.
      #
      # These extra checks won't be necessary once `available` becomes a part
      # of the core interface requirements and this class no longer wraps every
      # feature store.
      private def does_store_support_monitoring?
        return false unless @store.respond_to? :monitoring_enabled?
        return false unless @store.respond_to? :available?

        @store.monitoring_enabled?
      end
    end
  end
end
