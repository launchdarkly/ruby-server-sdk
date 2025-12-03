require 'concurrent'
require 'ldclient-rb/interfaces'

module LaunchDarkly
  module Impl
    module DataSource
      #
      # A minimal UpdateProcessor implementation used when the SDK is in offline mode
      # or daemon (LDD) mode. It does nothing except mark itself as initialized.
      #
      class NullUpdateProcessor
        include LaunchDarkly::Interfaces::DataSource

        #
        # Creates a new NullUpdateProcessor.
        #
        def initialize
          @ready = Concurrent::Event.new
        end

        #
        # Starts the data source. Since this is a null implementation, it immediately
        # sets the ready event to indicate initialization is complete.
        #
        # @return [Concurrent::Event] The ready event
        #
        def start
          @ready.set
          @ready
        end

        #
        # Stops the data source. This is a no-op for the null implementation.
        #
        # @return [void]
        #
        def stop
          # Nothing to do
        end

        #
        # Checks if the data source has been initialized.
        #
        # @return [Boolean] Always returns true since this is a null implementation
        #
        def initialized?
          true
        end
      end
    end
  end
end
