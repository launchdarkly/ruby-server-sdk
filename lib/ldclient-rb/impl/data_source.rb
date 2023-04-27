require "concurrent"
require "ldclient-rb/interfaces"
require "forwardable"

module LaunchDarkly
  module Impl
    module DataSource
      class StatusProvider
        include LaunchDarkly::Interfaces::DataSource::StatusProvider

        extend Forwardable
        def_delegators :@status_broadcaster, :add_listener, :remove_listener

        def initialize(status_broadcaster, updates_sink)
          # @type [Broadcaster]
          @status_broadcaster = status_broadcaster
          # @type [UpdateSink]
          @data_source_updates_sink = updates_sink
        end

        def status
          @data_source_updates_sink.current_status
        end
      end

      class UpdateSink
        include LaunchDarkly::Interfaces::DataSource::UpdateSink

        # @return [LaunchDarkly::Interfaces::DataSource::Status]
        attr_reader :current_status

        def initialize(data_store, status_broadcaster)
          # @type [LaunchDarkly::Interfaces::FeatureStore]
          @data_store = data_store
          # @type [Broadcaster]
          @status_broadcaster = status_broadcaster

          @mutex = Mutex.new
          @current_status = LaunchDarkly::Interfaces::DataSource::Status.new(
            LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING,
            Time.now,
            nil)
        end

        def init(all_data)
          monitor_store_update { @data_store.init(all_data) }
        end

        def upsert(kind, item)
          monitor_store_update { @data_store.upsert(kind, item) }
        end

        def delete(kind, key, version)
          monitor_store_update { @data_store.delete(kind, key, version) }
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
      end
    end
  end
end
