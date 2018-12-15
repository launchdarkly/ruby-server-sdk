
module LaunchDarkly
  # @private
  EventSummary = Struct.new(:start_date, :end_date, :counters)

  # Manages the state of summarizable information for the EventProcessor, including the
  # event counters and user deduplication. Note that the methods of this class are
  # deliberately not thread-safe; the EventProcessor is responsible for enforcing
  # synchronization across both the summarizer and the event queue.
  #
  # @private
  class EventSummarizer
    def initialize
      clear
    end

    # Adds this event to our counters, if it is a type of event we need to count.
    def summarize_event(event)
      if event[:kind] == "feature"
        counter_key = {
          key: event[:key],
          version: event[:version],
          variation: event[:variation]
        }
        c = @counters[counter_key]
        if c.nil?
          @counters[counter_key] = {
            value: event[:value],
            default: event[:default],
            count: 1
          }
        else
          c[:count] = c[:count] + 1
        end
        time = event[:creationDate]
        if !time.nil?
          @start_date = time if @start_date == 0 || time < @start_date
          @end_date = time if time > @end_date
        end
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
