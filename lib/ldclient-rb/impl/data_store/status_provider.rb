# frozen_string_literal: true

require "concurrent"
require "forwardable"
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

        extend Forwardable
        def_delegators :@status_broadcaster, :add_listener, :remove_listener

        #
        # Initialize the status provider.
        #
        # @param store [Object, nil] The feature store (may be nil for in-memory only)
        # @param status_broadcaster [LaunchDarkly::Impl::Broadcaster] Broadcaster for status changes
        #
        def initialize(store, status_broadcaster)
          @store = store
          @status_broadcaster = status_broadcaster
          @lock = Concurrent::ReadWriteLock.new
          @status = LaunchDarkly::Interfaces::DataStore::Status.new(true, false)
          @monitoring_enabled = store_supports_monitoring?
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

          @status_broadcaster.broadcast(status) if modified
        end

        # (see LaunchDarkly::Interfaces::DataStore::StatusProvider#status)
        def status
          @lock.with_read_lock do
            LaunchDarkly::Interfaces::DataStore::Status.new(@status.available, @status.stale)
          end
        end

        # (see LaunchDarkly::Interfaces::DataStore::StatusProvider#monitoring_enabled?)
        def monitoring_enabled?
          @monitoring_enabled
        end

        #
        # Determines whether the store supports monitoring.
        #
        # @return [Boolean]
        #
        private def store_supports_monitoring?
          return false if @store.nil?
          return false unless @store.respond_to?(:monitoring_enabled?)

          @store.monitoring_enabled?
        end
      end
    end
  end
end



