module LaunchDarkly
  module Interfaces
    #
    # An interface for tracking changes in feature flag configurations.
    #
    # An implementation of this interface is returned by {LaunchDarkly::LDClient#flag_tracker}.
    # Application code never needs to implement this interface.
    #
    module FlagTracker
      #
      # Registers a listener to be notified of feature flag changes in general.
      #
      # The listener will be notified whenever the SDK receives any change to any feature flag's configuration,
      # or to a user segment that is referenced by a feature flag. If the updated flag is used as a prerequisite
      # for other flags, the SDK assumes that those flags may now behave differently and sends flag change events
      # for them as well.
      #
      # Note that this does not necessarily mean the flag's value has changed for any particular evaluation
      # context, only that some part of the flag configuration was changed so that it may return a
      # different value than it previously returned for some context. If you want to track flag value changes,
      # use {#add_flag_value_change_listener} instead.
      #
      # It is possible, given current design restrictions, that a listener might be notified when no change has
      # occurred. This edge case will be addressed in a later version of the SDK. It is important to note this issue
      # does not affect {#add_flag_value_change_listener} listeners.
      #
      # If using the file data source, any change in a data file will be treated as a change to every flag. Again,
      # use {#add_flag_value_change_listener} (or just re-evaluate the flag # yourself) if you want to know whether
      # this is a change that really affects a flag's value.
      #
      # Change events only work if the SDK is actually connecting to LaunchDarkly (or using the file data source).
      # If the SDK is only reading flags from a database then it cannot know when there is a change, because
      # flags are read on an as-needed basis.
      #
      # The listener will be called from a worker thread.
      #
      # Calling this method for an already-registered listener has no effect.
      #
      # @param listener [#update]
      #
      def add_listener(listener) end

      #
      # Unregisters a listener so that it will no longer be notified of feature flag changes.
      #
      # Calling this method for a listener that was not previously registered has no effect.
      #
      # @param listener [Object]
      #
      def remove_listener(listener) end

      #
      # Registers a listener to be notified of a change in a specific feature flag's value for a specific
      # evaluation context.
      #
      # When you call this method, it first immediately evaluates the feature flag. It then uses
      # {#add_listener} to start listening for feature flag configuration
      # changes, and whenever the specified feature flag changes, it re-evaluates the flag for the same context.
      # It then calls your listener if and only if the resulting value has changed.
      #
      # All feature flag evaluations require an instance of {LaunchDarkly::LDContext}. If the feature flag you are
      # tracking does not have any context targeting rules, you must still pass a dummy context such as
      # `LDContext.with_key("for-global-flags")`. If you do not want the user to appear on your dashboard,
      # use the anonymous property: `LDContext.create({key: "for-global-flags", kind: "user", anonymous: true})`.
      #
      # The returned listener represents the subscription that was created by this method
      # call; to unsubscribe, pass that object (not your listener) to {#remove_listener}.
      #
      # @param key [Symbol]
      # @param context [LaunchDarkly::LDContext]
      # @param listener [#update]
      #
      def add_flag_value_change_listener(key, context, listener) end
    end

    #
    # Change event fired when some aspect of the flag referenced by the key has changed.
    #
    class FlagChange
      attr_accessor :key

      # @param [Symbol] key
      def initialize(key)
        @key = key
      end
    end

    #
    # Change event fired when the evaluated value for the specified flag key has changed.
    #
    class FlagValueChange
      attr_accessor :key
      attr_accessor :old_value
      attr_accessor :new_value

      # @param [Symbol] key
      # @param [Object] old_value
      # @param [Object] new_value
      def initialize(key, old_value, new_value)
        @key = key
        @old_value = old_value
        @new_value = new_value
      end
    end
  end
end
