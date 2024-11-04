require 'concurrent'
require "ldclient-rb/interfaces"

module LaunchDarkly
  module Impl
    module DataStore

      class DataKind
        FEATURES = "features".freeze
        SEGMENTS = "segments".freeze

        FEATURE_PREREQ_FN = lambda { |flag| (flag[:prerequisites] || []).map { |p| p[:key] } }.freeze

        attr_reader :namespace
        attr_reader :priority

        #
        # @param namespace [String]
        # @param priority [Integer]
        #
        def initialize(namespace:, priority:)
          @namespace = namespace
          @priority = priority
        end

        #
        # Maintain the same behavior when these data kinds were standard ruby hashes.
        #
        # @param key [Symbol]
        # @return [Object]
        #
        def [](key)
          return priority if key == :priority
          return namespace if key == :namespace
          return get_dependency_keys_fn() if key == :get_dependency_keys
          nil
        end

        #
        # Retrieve the dependency keys for a particular data kind. Right now, this is only defined for flags.
        #
        def get_dependency_keys_fn()
          return nil unless @namespace == FEATURES

          FEATURE_PREREQ_FN
        end

        def eql?(other)
          other.is_a?(DataKind) && namespace == other.namespace && priority == other.priority
        end

        def hash
          [namespace, priority].hash
        end
      end

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
