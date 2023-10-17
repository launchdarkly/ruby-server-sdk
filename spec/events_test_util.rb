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

def with_processor_and_sender(config, starting_timestamp)
  sender = FakeEventSender.new
  timestamp = starting_timestamp
  ep = LaunchDarkly::EventProcessor.new("sdk_key", config, nil, nil, {
    event_sender: sender,
    timestamp_fn: proc {
      t = timestamp
      timestamp += 1
      t
    },
  })

  begin
    yield ep, sender
  ensure
    ep.stop
  end
end

class FakeEventSender
  attr_accessor :result
  attr_reader :analytics_payloads
  attr_reader :diagnostic_payloads

  def initialize
    @result = LaunchDarkly::Impl::EventSenderResult.new(true, false, nil)
    @analytics_payloads = Queue.new
    @diagnostic_payloads = Queue.new
  end

  def send_event_data(data, description, is_diagnostic)
    (is_diagnostic ? @diagnostic_payloads : @analytics_payloads).push(JSON.parse(data, symbolize_names: true))
    @result
  end
end

#
# Overwrites the client's event process with an instance which captures events into the FakeEventSender.
#
# @param client [LaunchDarkly::LDClient]
# @param ep [LaunchDarkly::EventProcessor]
#
def override_client_event_processor(client, ep)
  client.instance_variable_set(:@event_processor, ep)
end
