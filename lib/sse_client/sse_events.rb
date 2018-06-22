
module SSE
  # Server-Sent Event type used by SSEClient and EventParser.
  SSEEvent = Struct.new(:type, :data, :id)

  SSESetRetryInterval = Struct.new(:milliseconds)

  #
  # Accepts lines of text via an iterator, and parses them into SSE messages.
  #
  class EventParser
    def initialize(lines)
      @lines = lines
      reset_buffers
    end

    # Generator that parses the input interator and returns instances of SSEEvent or SSERetryInterval.
    def items
      Enumerator.new do |gen|
        @lines.each do |line|
          line.chomp!
          if line.empty?
            event = maybe_create_event
            reset_buffers
            gen.yield event if !event.nil?
          else
            case line
              when /^(\w+): ?(.*)$/
                item = process_field($1, $2)
                gen.yield item if !item.nil?
            end
          end
        end
      end
    end

    private

    def reset_buffers
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
          @id = value
        when "retry"
          if /^(?<num>\d+)$/ =~ value
            return SSESetRetryInterval.new(num.to_i)
          end
      end
      nil
    end

    def maybe_create_event
      return nil if @data.empty?
      SSEEvent.new(@type || :message, @data, @id)
    end
  end
end
