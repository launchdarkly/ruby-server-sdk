# frozen_string_literal: true

require "concurrent"
require "forwardable"
require "ldclient-rb/impl/util"
require "ldclient-rb/interfaces"

module LaunchDarkly
  module Impl
    module DataSource
      #
      # Provides status tracking and listener management for data sources.
      #
      # This class implements the {LaunchDarkly::Interfaces::DataSource::StatusProvider} interface.
      # It maintains the current status of the data source and broadcasts status changes to listeners.
      #
      class StatusProviderV2
        include LaunchDarkly::Interfaces::DataSource::StatusProvider

        extend Forwardable
        def_delegators :@status_broadcaster, :add_listener, :remove_listener

        MONOTONIC_CLOCK = -> { Impl::Util.monotonic_seconds }
        private_constant :MONOTONIC_CLOCK

        #
        # Creates a new status provider.
        #
        # @param status_broadcaster [LaunchDarkly::Impl::Broadcaster] Broadcaster for status changes
        # @param clock [#call] returns seconds on a monotonic clock; injectable for tests
        #
        def initialize(status_broadcaster, clock: MONOTONIC_CLOCK)
          @status_broadcaster = status_broadcaster
          @clock = clock
          @status = LaunchDarkly::Interfaces::DataSource::Status.new(
            LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING,
            Time.now,
            nil
          )
          @state_since_monotonic = @clock.call
          @lock = Concurrent::ReadWriteLock.new
        end

        # (see LaunchDarkly::Interfaces::DataSource::StatusProvider#status)
        def status
          @lock.with_read_lock do
            @status
          end
        end

        #
        # Returns the current status and the seconds it has been in that state.
        #
        # One lock acquisition keeps the pair consistent. The seconds are
        # monotonic — use them for duration decisions instead of arithmetic on
        # the wall-clock `state_since`.
        #
        # @private
        # @return [Array(LaunchDarkly::Interfaces::DataSource::Status, Float)]
        #
        def status_and_seconds_in_state
          @lock.with_read_lock do
            [@status, @clock.call - @state_since_monotonic]
          end
        end

        # (see LaunchDarkly::Interfaces::DataSource::UpdateSink#update_status)
        def update_status(new_state, new_error)
          return if new_state.nil?

          status_to_broadcast = nil

          @lock.with_write_lock do
            old_status = @status

            # Special handling: INTERRUPTED during INITIALIZING stays INITIALIZING
            if new_state == LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED &&
                old_status.state == LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING
              new_state = LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING
            end

            # Special handling: You can't go back to INITIALIZING after being anything else
            if new_state == LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING && !old_status.state.nil?
              new_state = old_status.state
            end

            # No change if state is the same and no error
            return if new_state == old_status.state && new_error.nil?

            if new_state == old_status.state
              new_since = @status.state_since
            else
              new_since = Time.now
              @state_since_monotonic = @clock.call
            end
            new_error = @status.last_error if new_error.nil?

            @status = LaunchDarkly::Interfaces::DataSource::Status.new(
              new_state,
              new_since,
              new_error
            )

            status_to_broadcast = @status
          end

          @status_broadcaster.broadcast(status_to_broadcast) if status_to_broadcast
        end
      end
    end
  end
end

