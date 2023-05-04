# frozen_string_literal: true

module LaunchDarkly
  module Impl

    #
    # A generic mechanism for registering event listeners and broadcasting
    # events to them.
    #
    # The SDK maintains an instance of this for each available type of listener
    # (flag change, data store status, etc.). They are all intended to share a
    # single executor service; notifications are submitted individually to this
    # service for each listener.
    #
    class Broadcaster
      def initialize(executor, logger)
        @listeners = Concurrent::Set.new
        @executor = executor
        @logger = logger
      end

      #
      # Register a listener to this broadcaster.
      #
      # @param listener [#update]
      #
      def add_listener(listener)
        unless listener.respond_to? :update
          logger.warn("listener (#{listener.class}) does not respond to :update method. ignoring as registered listener")
          return
        end

        listeners.add(listener)
      end

      #
      # Removes a registered listener from this broadcaster.
      #
      def remove_listener(listener)
        listeners.delete(listener)
      end

      def has_listeners?
        !listeners.empty?
      end

      #
      # Broadcast the provided event to all registered listeners.
      #
      # Each listener will be notified using the broadcasters executor. This
      # method is non-blocking.
      #
      def broadcast(event)
        listeners.each do |listener|
          executor.post do
            begin
              listener.update(event)
            rescue StandardError => e
              logger.error("listener (#{listener.class}) raised exception (#{e}) processing event (#{event.class})")
            end
          end
        end
      end


      private

      # @return [Concurrent::ThreadPoolExecutor]
      attr_reader :executor

      # @return [Logger]
      attr_reader :logger

      # @return [Concurrent::Set]
      attr_reader :listeners
    end
  end
end
