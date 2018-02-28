module LaunchDarkly
  class EventStreamParser
    LF = 10
    Event = Struct.new(:id, :type, :data, :retry)

    def initialize
      @events = []
      @buf = []
    end

    def <<(str)
      return self unless str
      str.each_byte do |b|
        if b == LF && @buf[-1] == LF # End of previous event
          if event = parse_event(@buf.pack('C*'))
            @events << event
          end
          @buf.clear
        else
          @buf << b
        end
      end
      self
    end

    def take_events
      @events.dup.tap { @events.clear }
    end

    def pending?
      @buf.any?
    end

    def parse_event(event_fields_str)
      evt_type = nil
      evt_id = nil
      evt_data = []
      evt_retry = nil
      event_fields_str.split("\n").each do |line|
        if line.start_with?('event:')
          evt_type = extract_line_payload(line)
        elsif line.start_with?('id:')
          evt_id = extract_line_payload(line)
        elsif line.start_with?('retry:')
          evt_retry = extract_line_payload(line).to_i # Decimal, milliseconds
        elsif line.start_with?('data:')
          # The spec is a bit contradictory here. They say that every part of "data"
          # should be followed by a LF character. However, in the example lower down
          # they demonstrate that the following stream:
          #   data: YHOO
          #   data: +2
          #   data: 10
          # is supposed to yield the following data payload:
          #   "YHOO\n+2\n10"
          # So in practice the spec should read "append an LF unless this data item is the last"
          # https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation
          # Let's hope this will not pose a problem down the road.
          evt_data << extract_line_payload(line) << "\n"
        end
      end

      if !evt_type && !evt_id && evt_data.empty? && !evt_id && !evt_retry
        return
      end

      Event.new(evt_id, evt_type, evt_data.join, evt_retry)
    end

    private

    def extract_line_payload(field)
      field.split(':', 2)[-1].gsub(/^\s+/, '').chomp
    end
  end
end
