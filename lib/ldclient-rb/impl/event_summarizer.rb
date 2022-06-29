require "ldclient-rb/impl/event_types"

module LaunchDarkly
  module Impl
    EventSummary = Struct.new(:start_date, :end_date, :counters)

    EventSummaryFlagInfo = Struct.new(:default, :versions)

    EventSummaryFlagVariationCounter = Struct.new(:value, :count)

    # Manages the state of summarizable information for the EventProcessor, including the
    # event counters and user deduplication. Note that the methods of this class are
    # deliberately not thread-safe; the EventProcessor is responsible for enforcing
    # synchronization across both the summarizer and the event queue.
    class EventSummarizer
      class Counter
      end

      def initialize
        clear
      end

      # Adds this event to our counters, if it is a type of event we need to count.
      def summarize_event(event)
        return if !event.is_a?(LaunchDarkly::Impl::EvalEvent)

        counters_for_flag = @counters[event.key]
        if counters_for_flag.nil?
          counters_for_flag = EventSummaryFlagInfo.new(event.default, Hash.new)
          @counters[event.key] = counters_for_flag
        end
        counters_for_flag_version = counters_for_flag.versions[event.version]
        if counters_for_flag_version.nil?
          counters_for_flag_version = Hash.new
          counters_for_flag.versions[event.version] = counters_for_flag_version
        end
        variation_counter = counters_for_flag_version[event.variation]
        if variation_counter.nil?
          counters_for_flag_version[event.variation] = EventSummaryFlagVariationCounter.new(event.value, 1)
        else
          variation_counter.count = variation_counter.count + 1
        end
        time = event.timestamp
        if !time.nil?
          @start_date = time if @start_date == 0 || time < @start_date
          @end_date = time if time > @end_date
        end
      end

      # Returns a snapshot of the current summarized event data, and resets this state.
      def snapshot
        ret = EventSummary.new(@start_date, @end_date, @counters)
        ret
      end

      def clear
        @start_date = 0
        @end_date = 0
        @counters = {}
      end
    end
  end
end
