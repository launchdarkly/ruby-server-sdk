require 'http'
require 'json'

#
# A listener that receives FlagChange events and POSTs notifications to a callback URI.
# Implements the #update method expected by the SDK's FlagTracker.
#
class FlagChangeCallbackListener
  def initialize(listener_id, callback_uri)
    @listener_id = listener_id
    @callback_uri = callback_uri
  end

  # @param flag_change [LaunchDarkly::Interfaces::FlagChange]
  def update(flag_change)
    payload = {
      listenerId: @listener_id,
      flagKey: flag_change.key,
    }
    HTTP.post(@callback_uri, json: payload)
  rescue => e
    # Log but don't re-raise; listener errors shouldn't crash the test service
    $log.error("FlagChangeCallbackListener POST failed: #{e}")
  end
end

#
# A listener that receives FlagValueChange events and POSTs notifications to a callback URI.
# Implements the #update method expected by the SDK's FlagTracker (via FlagValueChangeAdapter).
#
class FlagValueChangeCallbackListener
  def initialize(listener_id, callback_uri)
    @listener_id = listener_id
    @callback_uri = callback_uri
  end

  # @param flag_value_change [LaunchDarkly::Interfaces::FlagValueChange]
  def update(flag_value_change)
    payload = {
      listenerId: @listener_id,
      flagKey: flag_value_change.key,
      oldValue: flag_value_change.old_value,
      newValue: flag_value_change.new_value,
    }
    HTTP.post(@callback_uri, json: payload)
  rescue => e
    $log.error("FlagValueChangeCallbackListener POST failed: #{e}")
  end
end

#
# Manages all active flag change listener registrations for a single SDK client entity.
# Thread-safe via a Mutex.
#
class ListenerRegistry
  # @param tracker [LaunchDarkly::Interfaces::FlagTracker]
  def initialize(tracker)
    @tracker = tracker
    @mu = Mutex.new
    @listeners = {} # listenerId => listener object to pass to remove_listener
  end

  # Registers a general flag change listener that fires on any flag configuration change.
  #
  # @param listener_id [String]
  # @param callback_uri [String]
  def register_flag_change_listener(listener_id, callback_uri)
    listener = FlagChangeCallbackListener.new(listener_id, callback_uri)
    store_listener(listener_id, listener)
    @tracker.add_listener(listener)
  end

  # Registers a flag value change listener that fires when the evaluated value of a
  # specific flag changes for a given context.
  #
  # @param listener_id [String]
  # @param flag_key [String]
  # @param context [LaunchDarkly::LDContext]
  # @param callback_uri [String]
  def register_flag_value_change_listener(listener_id, flag_key, context, callback_uri)
    inner_listener = FlagValueChangeCallbackListener.new(listener_id, callback_uri)
    # add_flag_value_change_listener returns the adapter object that must be passed to
    # remove_listener for unregistration.
    adapter = @tracker.add_flag_value_change_listener(flag_key, context, inner_listener)
    store_listener(listener_id, adapter)
  end

  # Unregisters a previously registered listener by its ID.
  #
  # @param listener_id [String]
  # @return [Boolean] true if the listener was found and removed
  def unregister(listener_id)
    listener = nil
    @mu.synchronize do
      listener = @listeners.delete(listener_id)
    end

    return false if listener.nil?

    @tracker.remove_listener(listener)
    true
  end

  # Removes all registered listeners. Called when the SDK client entity shuts down.
  def close_all
    listeners_to_remove = nil
    @mu.synchronize do
      listeners_to_remove = @listeners.values
      @listeners = {}
    end

    listeners_to_remove.each do |listener|
      @tracker.remove_listener(listener)
    end
  end

  private

  # Stores a listener, cancelling any previously registered listener with the same ID.
  def store_listener(listener_id, listener)
    old_listener = nil
    @mu.synchronize do
      old_listener = @listeners[listener_id]
      @listeners[listener_id] = listener
    end

    @tracker.remove_listener(old_listener) if old_listener
  end
end
