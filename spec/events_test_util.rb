require "ldclient-rb/impl/event_types"

def make_eval_event(timestamp, context, key, version = nil, variation = nil, value = nil, reason = nil,
    default = nil, track_events = false, debug_until = nil, prereq_of = nil)
  LaunchDarkly::Impl::EvalEvent.new(timestamp, context, key, version, variation, value, reason,
    default, track_events, debug_until, prereq_of)
end

def make_identify_event(timestamp, context)
  LaunchDarkly::Impl::IdentifyEvent.new(timestamp, context)
end

def make_custom_event(timestamp, context, key, data = nil, metric_value = nil)
  LaunchDarkly::Impl::CustomEvent.new(timestamp, context, key, data, metric_value)
end
