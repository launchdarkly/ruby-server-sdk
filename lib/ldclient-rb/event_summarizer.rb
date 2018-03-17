
module LaunchDarkly
  EventSummarySnapshot = Struct.new(:start_date, :end_date, :counters)

  # Manages the state of summarizable information for the EventProcessor, including the
  # event counters and user deduplication. Note that the methods of this class are
  # deliberately not thread-safe; the EventProcessor is responsible for enforcing
  # synchronization across both the summarizer and the event queue.
  class EventSummarizer
    def initialize(config)
      @config = config
      @users = SimpleLRUCacheSet.new(@config.user_keys_capacity)
      reset_state
    end

    # Adds to the set of users we've noticed, and return true if the user was already known to us.
    def notice_user(user)
      if user.nil? || !user.has_key?(:key)
        true
      else
        @users.add(user[:key])
      end
    end

    # Resets the set of users we've seen.
    def reset_users
      @users.reset
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
      ret = {
        start_date: @start_date,
        end_date: @end_date,
        counters: @counters
      }
      reset_state
      ret
    end

    # Transforms the summary data into the format used for event sending.
    def output(snapshot)
      flags = {}
      snapshot[:counters].each { |ckey, cval|
        flag = flags[ckey[:key]]
        if flag.nil?
          flag = {
            default: cval[:default],
            counters: []
          }
          flags[ckey[:key]] = flag
        end
        c = {
          value: cval[:value],
          count: cval[:count]
        }
        if ckey[:version].nil?
          c[:unknown] = true
        else
          c[:version] = ckey[:version]
        end
        flag[:counters].push(c)
      }
      {
        startDate: snapshot[:start_date],
        endDate: snapshot[:end_date],
        features: flags
      }
    end

    private

    def reset_state
      @start_date = 0
      @end_date = 0
      @counters = {}
    end
  end
end
