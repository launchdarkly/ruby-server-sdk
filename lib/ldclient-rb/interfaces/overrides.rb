# frozen_string_literal: true

module LaunchDarkly
  module Interfaces
    #
    # Interfaces for flag overrides. Overrides are flag and segment definitions that take
    # precedence over data received from LaunchDarkly at evaluation time, on a per-key basis.
    # They exist for resilience during an incident. An operator can force one or more flags to
    # a known state on a running client, whether or not the client can reach LaunchDarkly.
    #
    # Flag overrides are currently experimental and subject to change.
    #
    module Overrides
      #
      # Receives the contents of the SDK's override store. The SDK implements it and passes it
      # to an {OverrideSource}'s `start` method. Override sources call it. They do not implement it.
      #
      # Flag overrides are currently experimental and subject to change.
      #
      module OverrideSink
        #
        # Replaces the entire override store with the given flag and segment definitions. Each
        # call is a full snapshot. Entries absent from the call are removed. Empty collections
        # clear the store.
        #
        # Each definition is either a data model object, as produced by
        # `LaunchDarkly::Impl::Model.deserialize`, or a hash in the flag or segment data model.
        # The SDK itself marks the entries as overrides.
        #
        # This method is safe to call from any thread. Calls are serialized by the SDK, and the
        # new contents are visible to evaluations when the call returns.
        #
        # @param flags [Enumerable<LaunchDarkly::Impl::Model::FeatureFlag, Hash>] full flag definitions
        # @param segments [Enumerable<LaunchDarkly::Impl::Model::Segment, Hash>] full segment definitions
        # @return [void]
        #
        def set_overrides(flags, segments)
          raise NotImplementedError, "#{self.class} must implement #set_overrides"
        end
      end

      #
      # Supplies flag and segment overrides that take precedence over LaunchDarkly data at
      # evaluation time, on a per-key basis.
      #
      # An override source is not a data source. It does not take part in the data system's
      # initializer and synchronizer pipeline. The override store it populates has no effect on
      # the client's initialization status, data availability, or data source status.
      #
      # To configure an override source, use {LaunchDarkly::DataSystem::ConfigBuilder#overrides}.
      #
      # Flag overrides are currently experimental and subject to change.
      #
      module OverrideSource
        #
        # Begins supplying overrides to the sink and returns without blocking on long-running
        # work. An implementation performs an initial load synchronously, then pushes a full
        # replacement snapshot to the sink whenever its backing data changes, until `stop` is
        # called. A failed load leaves the previously supplied store untouched by not calling
        # the sink.
        #
        # The SDK calls this method at most once, before any call to `stop`.
        #
        # @param sink [OverrideSink]
        # @return [void]
        #
        def start(sink)
          raise NotImplementedError, "#{self.class} must implement #start"
        end

        #
        # Stops the source and releases any resources it holds.
        #
        # @return [void]
        #
        def stop
          raise NotImplementedError, "#{self.class} must implement #stop"
        end
      end
    end
  end
end
