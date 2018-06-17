module LaunchDarkly
  class EventStreamParser
    MessageEvent = Struct.new(:id, :type, :data)

    def initialize(on_retry)
      clear_buffers!
      @on_retry = on_retry
      @last_truncated_line = "" # Remember the potentially truncated last line of the previous chunk.
    end

    def parse_chunk(chunk)
      return self unless chunk

      # Prepend the current chunk with the truncated line from the previous chunk
      # and reset @last_truncated_line to empty string.
      chunk = @last_truncated_line + chunk
      @last_truncated_line = ""

      # Check if the chunk ends with a truncated line. If so, remove it from the chunk
      # and store it in @last_truncated_line in order to be processed with the following chunk.
      last_line = chunk.lines.last
      if !last_line.nil? && !last_line.end_with?("\n")
        chunk = chunk[0...-last_line.length]
        @last_truncated_line = last_line
      end

      # Process every line of the chunk.
      chunk.each_line do |line|
        # If the line is empty dispatch the event and clear the buffers.
        # Else parse the line.
        if line.strip.empty?
          begin
            event = create_event
            yield event unless event.nil?
          ensure
            clear_buffers!
          end
        else
          parse_line(line)
        end
      end
      self
    end

    private

    # Don't create an event if the data buffer is empty.
    # If the data buffer's last character is a line feed character,
    # then remove the last character from the data buffer.
    # If the type buffer is empty set the event's type attribute
    # to :message. Else set it to the type buffer's value.
    # Returns a MessageEvent.
    def create_event
      return nil if @data_buffer.empty?

      @data_buffer.chomp!("\n") if @data_buffer.end_with?("\n")
      # If the type buffer is empty set the event's type attribute to :message. Else set it to the type buffer's value.
      evt_type = @type_buffer.empty? ? :message : @type_buffer.to_sym
      MessageEvent.new(@id_buffer, evt_type, @data_buffer)
    end

    # If the line starts with a colon character, ignore the line.
    # If the line starts with a colon character:
    #  * Collect the characters on the line before the first collon character and let field be that string.
    #  * Collect the characters on the line after the first collon character and let value be that string.
    #    If value starts with a space character, remove it from value.
    # Otherwise, if the line is not empty but does not contain a colon character
    # use the whole line as the field name, and the empty string as the field value.
    def parse_line(line)
      case line
        when /^:.*$/
        when /^(\w+): ?(.*)$/
          process_field($1, $2)
        else
          process_field(line, "")
      end
    end

    # If the field name is event, set the event type buffer to field value.
    # If the field name is data, append the field value to the data buffer,
    # then append a single line feed character to the data buffer.
    # If the field name is id and the field value does not contain U+0000 NULL,
    # then set the last event ID buffer to the field value. Otherwise, ignore the field.
    # If the field name is retry and the field value consists of only ASCII digits,
    # then interpret the field value as an integer in base ten, and set the event stream's
    # reconnection time to that integer. Otherwise, ignore the field.
    # Otherwise ignore the field.
    def process_field(field_name, field_value)
      case field_name
        when "event"
          @type_buffer = field_value
        when "data"
          @data_buffer << field_value.concat("\n")
        when "id"
          @id_buffer = field_value unless field_value.include? "u\0000"
        when "retry"
          if /^(?<num>\d+)$/ =~ field_value
            @on_retry.call(num.to_i)
          end
      end
    end

    # Set the data buffer, the event type buffer and the event id buffer to the empty string.
    def clear_buffers!
      @data_buffer = ""
      @type_buffer = ""
      @id_buffer = ""
    end
  end
end
