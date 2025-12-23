# frozen_string_literal: true

require "concurrent"
require "ldclient-rb/interfaces"

module LaunchDarkly
  module Impl
    module DataStore
      #
      # StatusProviderV2 is the FDv2-specific implementation of {LaunchDarkly::Interfaces::DataStore::StatusProvider}.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      class StatusProviderV2
        include LaunchDarkly::Interfaces::DataStore::StatusProvider

        #
        # Initialize the status provider.
        #
        # @param store [Object, nil] The feature store (may be nil for in-memory only)
        # @param listeners [LaunchDarkly::Impl::Broadcaster] Broadcaster for status changes
        #
        def initialize(store, listeners)
          @store = store
          @listeners = listeners
          @lock = Concurrent::ReadWriteLock.new
          @status = LaunchDarkly::Interfaces::DataStore::Status.new(true, false)
        end

        # (see LaunchDarkly::Interfaces::DataStore::UpdateSink#update_status)
        def update_status(status)
          modified = false

          @lock.with_write_lock do
            if @status.available != status.available || @status.stale != status.stale
              @status = status
              modified = true
            end
          end

          @listeners.broadcast(status) if modified
        end

        # (see LaunchDarkly::Interfaces::DataStore::StatusProvider#status)
        def status
          @lock.with_read_lock do
            LaunchDarkly::Interfaces::DataStore::Status.new(@status.available, @status.stale)
          end
        end

        # (see LaunchDarkly::Interfaces::DataStore::StatusProvider#monitoring_enabled?)
        def monitoring_enabled?
          return false if @store.nil?
          return false unless @store.respond_to?(:monitoring_enabled?)

          @store.monitoring_enabled?
        end

        # (see LaunchDarkly::Interfaces::DataStore::StatusProvider#add_listener)
        def add_listener(listener)
          @listeners.add(listener)
        end

        # (see LaunchDarkly::Interfaces::DataStore::StatusProvider#remove_listener)
        def remove_listener(listener)
          @listeners.remove(listener)
        end
      end
    end
  end
end



