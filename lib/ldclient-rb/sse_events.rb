
module LaunchDarkly
  # Server-Sent Event type used by SSEClient and EventParser.
  SSEEvent = Struct.new(:type, :data, :id)
  
  #
  # Accepts lines of text and parses them into SSE messages, which it emits via a callback.
  #
  class EventParser
    def initialize
      @on = { event: ->(_) {}, retry: ->(_) {} }
      reset
    end

    def on(event_name, &action)
      @on[event_name] = action
    end

    def <<(line)
      line.chomp!
      if line.empty?
        return if @data.empty?
        event = SSEEvent.new(@type || :message, @data, @id)
        reset
        @on[:event].call(event)
      else
        case line
          when /^:.*$/
          when /^(\w+): ?(.*)$/
            process_field($1, $2)
        end
      end
    end

    private

    def reset
      @id = nil
      @type = nil
      @data = ""
    end

    def process_field(name, value)
      case name
        when "event"
          @type = value.to_sym
        when "data"
          @data << "\n" if !@data.empty?
          @data << value
        when "id"
          @id = field_value
        when "retry"
          if /^(?<num>\d+)$/ =~ value
            @on_retry.call(num.to_i)
          end
      end
    end
  end
end
