require 'concurrent'
require "ldclient-rb/interfaces"

module LaunchDarkly
  module Impl
    module DataStore
      class StatusProvider
        include LaunchDarkly::Interfaces::DataStore::StatusProvider

        def initialize(store, update_sink)
          # @type [LaunchDarkly::Impl::FeatureStoreClientWrapper]
          @store = store
          # @type [UpdateSink]
          @update_sink = update_sink
        end

        def status
          @update_sink.last_status.get
        end

        def monitoring_enabled?
          @store.monitoring_enabled?
        end

        def add_listener(listener)
          @update_sink.broadcaster.add_listener(listener)
        end

        def remove_listener(listener)
          @update_sink.broadcaster.remove_listener(listener)
        end
      end

      class UpdateSink
        include LaunchDarkly::Interfaces::DataStore::UpdateSink

        # @return [LaunchDarkly::Impl::Broadcaster]
        attr_reader :broadcaster

        # @return [Concurrent::AtomicReference]
        attr_reader :last_status

        def initialize(broadcaster)
          @broadcaster = broadcaster
          @last_status = Concurrent::AtomicReference.new(
            LaunchDarkly::Interfaces::DataStore::Status.new(true, false)
          )
        end

        def update_status(status)
          return if status.nil?

          old_status = @last_status.get_and_set(status)
          @broadcaster.broadcast(status) unless old_status == status
        end
      end
    end
  end
end
