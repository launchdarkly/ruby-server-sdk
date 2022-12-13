require "ldclient-rb/impl/event_types"

require "events_test_util"
require "spec_helper"
require "set"

module LaunchDarkly
  module Impl
    describe EventSummarizer do
      subject { EventSummarizer }

      let(:context) { LaunchDarkly::LDContext.create({ key: "key" }) }

      it "does not add identify event to summary" do
        es = subject.new
        snapshot = es.snapshot
        es.summarize_event({ kind: "identify", context: context })

        expect(es.snapshot).to eq snapshot
      end

      it "does not add custom event to summary" do
        es = subject.new
        snapshot = es.snapshot
        es.summarize_event({ kind: "custom", key: "whatever", context: context })

        expect(es.snapshot).to eq snapshot
      end

      it "tracks start and end dates" do
        es = subject.new
        flag = { key: "key" }
        event1 = make_eval_event(2000, context, 'flag1')
        event2 = make_eval_event(1000, context, 'flag1')
        event3 = make_eval_event(1500, context, 'flag1')
        es.summarize_event(event1)
        es.summarize_event(event2)
        es.summarize_event(event3)
        data = es.snapshot

        expect(data.start_date).to be 1000
        expect(data.end_date).to be 2000
      end

      it "counts events" do
        es = subject.new
        flag1 = { key: "key1", version: 11 }
        flag2 = { key: "key2", version: 22 }
        event1 = make_eval_event(0, context, 'key1', 11, 1, 'value1', nil, 'default1')
        event2 = make_eval_event(0, context, 'key1', 11, 2, 'value2', nil, 'default1')
        event3 = make_eval_event(0, context, 'key2', 22, 1, 'value99', nil, 'default2')
        event4 = make_eval_event(0, context, 'key1', 11, 1, 'value99', nil, 'default1')
        event5 = make_eval_event(0, context, 'badkey', nil, nil, 'default3', nil, 'default3')
        [event1, event2, event3, event4, event5].each { |e| es.summarize_event(e) }
        data = es.snapshot

        expectedCounters = {
          'key1' => EventSummaryFlagInfo.new(
            'default1', {
              11 => {
                1 => EventSummaryFlagVariationCounter.new('value1', 2),
                2 => EventSummaryFlagVariationCounter.new('value2', 1),
              },
            },
            Set.new(["user"])
          ),
          'key2' => EventSummaryFlagInfo.new(
            'default2', {
              22 => {
                1 => EventSummaryFlagVariationCounter.new('value99', 1),
              },
            },
            Set.new(["user"])
          ),
          'badkey' => EventSummaryFlagInfo.new(
            'default3', {
              nil => {
                nil => EventSummaryFlagVariationCounter.new('default3', 1),
              },
            },
            Set.new(["user"])
          ),
        }
        expect(data.counters).to eq expectedCounters
      end
    end
  end
end
