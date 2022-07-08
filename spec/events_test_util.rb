require "ldclient-rb/impl/event_types"

def make_eval_event(timestamp, user, key, version = nil, variation = nil, value = nil, reason = nil,
    default = nil, track_events = false, debug_until = nil, prereq_of = nil)
  LaunchDarkly::Impl::EvalEvent.new(timestamp, user, key, version, variation, value, reason,
    default, track_events, debug_until, prereq_of)
end

def make_identify_event(timestamp, user)
  LaunchDarkly::Impl::IdentifyEvent.new(timestamp, user)
end

def make_custom_event(timestamp, user, key, data = nil, metric_value = nil)
  LaunchDarkly::Impl::CustomEvent.new(timestamp, user, key, data, metric_value)
end
