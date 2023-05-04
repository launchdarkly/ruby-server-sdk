require "concurrent"
require "forwardable"
require "ldclient-rb/impl/dependency_tracker"
require "ldclient-rb/interfaces"
require "set"

module LaunchDarkly
  module Impl
    module DataSource
      class StatusProvider
        include LaunchDarkly::Interfaces::DataSource::StatusProvider

        extend Forwardable
        def_delegators :@status_broadcaster, :add_listener, :remove_listener

        def initialize(status_broadcaster, update_sink)
          # @type [Broadcaster]
          @status_broadcaster = status_broadcaster
          # @type [UpdateSink]
          @data_source_update_sink = update_sink
        end

        def status
          @data_source_update_sink.current_status
        end
      end

      class UpdateSink
        include LaunchDarkly::Interfaces::DataSource::UpdateSink

        # @return [LaunchDarkly::Interfaces::DataSource::Status]
        attr_reader :current_status

        def initialize(data_store, status_broadcaster, flag_change_broadcaster)
          # @type [LaunchDarkly::Interfaces::FeatureStore]
          @data_store = data_store
          # @type [Broadcaster]
          @status_broadcaster = status_broadcaster
          # @type [Broadcaster]
          @flag_change_broadcaster = flag_change_broadcaster
          @dependency_tracker = LaunchDarkly::Impl::DependencyTracker.new

          @mutex = Mutex.new
          @current_status = LaunchDarkly::Interfaces::DataSource::Status.new(
            LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING,
            Time.now,
            nil)
        end

        def init(all_data)
          old_data = nil
          monitor_store_update do
            if @flag_change_broadcaster.has_listeners?
              old_data = {}
              LaunchDarkly::ALL_KINDS.each do |kind|
                old_data[kind] = @data_store.all(kind)
              end
            end

            @data_store.init(all_data)
          end

          update_full_dependency_tracker(all_data)

          return if old_data.nil?

          send_change_events(
            compute_changed_items_for_full_data_set(old_data, all_data)
          )
        end

        def upsert(kind, item)
          monitor_store_update { @data_store.upsert(kind, item) }

          # TODO(sc-197908): We only want to do this if the store successfully
          # updates the record.
          @dependency_tracker.update_dependencies_from(kind, item[:key], item)
          if @flag_change_broadcaster.has_listeners?
            affected_items = Set.new
            @dependency_tracker.add_affected_items(affected_items, {kind: kind, key: item[:key]})
            send_change_events(affected_items)
          end
        end

        def delete(kind, key, version)
          monitor_store_update { @data_store.delete(kind, key, version) }

          @dependency_tracker.update_dependencies_from(kind, key, nil)
          if @flag_change_broadcaster.has_listeners?
            affected_items = Set.new
            @dependency_tracker.add_affected_items(affected_items, {kind: kind, key: key})
            send_change_events(affected_items)
          end
        end

        def update_status(new_state, new_error)
          return if new_state.nil?

          status_to_broadcast = nil

          @mutex.synchronize do
            old_status = @current_status

            if new_state == LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED && old_status.state == LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING
              # See {LaunchDarkly::Interfaces::DataSource::UpdateSink#update_status} for more information
              new_state = LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING
            end

            unless new_state == old_status.state && new_error.nil?
              @current_status = LaunchDarkly::Interfaces::DataSource::Status.new(
                new_state,
                new_state == current_status.state ? current_status.state_since : Time.now,
                new_error.nil? ? current_status.last_error : new_error
              )
              status_to_broadcast = current_status
            end
          end

          @status_broadcaster.broadcast(status_to_broadcast) unless status_to_broadcast.nil?
        end

        private def update_full_dependency_tracker(all_data)
          @dependency_tracker.reset
          all_data.each do |kind, items|
            items.each do |key, item|
              @dependency_tracker.update_dependencies_from(kind, item.key, item)
            end
          end
        end


        #
        # Method to monitor updates to the store. You provide a block to update
        # the store. This mthod wraps that block, catching and re-raising all
        # errors, and notifying all status listeners of the error.
        #
        private def monitor_store_update
          begin
            yield
          rescue => e
            error_info = LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(LaunchDarkly::Interfaces::DataSource::ErrorInfo::STORE_ERROR, 0, e.to_s, Time.now)
            update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, error_info)
            raise
          end
        end


        #
        # @param [Hash] old_data
        # @param [Hash] new_data
        # @return [Set]
        #
        private def compute_changed_items_for_full_data_set(old_data, new_data)
          affected_items = Set.new

          LaunchDarkly::ALL_KINDS.each do |kind|
            old_items = old_data[kind] || {}
            new_items = new_data[kind] || {}

            old_items.keys.concat(new_items.keys).each do |key|
              old_item = old_items[key]
              new_item = new_items[key]

              next if old_item.nil? && new_item.nil?

              if old_item.nil? || new_item.nil? || old_item[:version] < new_item[:version]
                @dependency_tracker.add_affected_items(affected_items, {kind: kind, key: key.to_s})
              end
            end
          end

          affected_items
        end

        #
        # @param affected_items [Set]
        #
        private def send_change_events(affected_items)
          affected_items.each do |item|
            if item[:kind] == LaunchDarkly::FEATURES
              @flag_change_broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(item[:key]))
            end
          end
        end
      end
    end
  end
end
