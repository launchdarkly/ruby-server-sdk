require "ldclient-rb/impl/model/serialization"

require "concurrent/atomics"
require "json"
require "ld-eventsource"

module LaunchDarkly
  # @private
  PUT = :put
  # @private
  PATCH = :patch
  # @private
  DELETE = :delete
  # @private
  READ_TIMEOUT_SECONDS = 300  # 5 minutes; the stream should send a ping every 3 minutes

  # @private
  KEY_PATHS = {
    FEATURES => "/flags/",
    SEGMENTS => "/segments/"
  }

  # @private
  class StreamProcessor
    def initialize(sdk_key, config, diagnostic_accumulator = nil)
      @sdk_key = sdk_key
      @config = config
      @data_store = config.data_store
      @initialized = Concurrent::AtomicBoolean.new(false)
      @started = Concurrent::AtomicBoolean.new(false)
      @stopped = Concurrent::AtomicBoolean.new(false)
      @ready = Concurrent::Event.new
      @connection_attempt_start_time = 0
    end

    def initialized?
      @initialized.value
    end

    def start
      return @ready unless @started.make_true

      @config.logger.info { "[LDClient] Initializing stream connection" }
      
      headers = Impl::Util.default_http_headers(@sdk_key, @config)
      opts = {
        headers: headers,
        read_timeout: READ_TIMEOUT_SECONDS,
        logger: @config.logger
      }
      log_connection_started
      @es = SSE::Client.new(@config.stream_uri + "/all", **opts) do |conn|
        conn.on_event { |event| process_message(event) }
        conn.on_error { |err|
          log_connection_result(false)
          case err
          when SSE::Errors::HTTPStatusError
            status = err.status
            message = Util.http_error_message(status, "streaming connection", "will retry")
            @config.logger.error { "[LDClient] #{message}" }
            if !Util.http_error_recoverable?(status)
              @ready.set  # if client was waiting on us, make it stop waiting - has no effect if already set
              stop
            end
          end
        }
      end
      
      @ready
    end

    def stop
      if @stopped.make_true
        @es.close
        @config.logger.info { "[LDClient] Stream connection stopped" }
      end
    end

    private

    def process_message(message)
      log_connection_result(true)
      method = message.type
      @config.logger.debug { "[LDClient] Stream received #{method} message: #{message.data}" }
      if method == PUT
        message = JSON.parse(message.data, symbolize_names: true)
        all_data = Impl::Model.make_all_store_data(message[:data])
        @data_store.init(all_data)
        @initialized.make_true
        @config.logger.info { "[LDClient] Stream initialized" }
        @ready.set
      elsif method == PATCH
        data = JSON.parse(message.data, symbolize_names: true)
        for kind in [FEATURES, SEGMENTS]
          key = key_for_path(kind, data[:path])
          if key
            data = data[:data]
            Impl::Model.postprocess_item_after_deserializing!(kind, data)
            @data_store.upsert(kind, data)
            break
          end
        end
      elsif method == DELETE
        data = JSON.parse(message.data, symbolize_names: true)
        for kind in [FEATURES, SEGMENTS]
          key = key_for_path(kind, data[:path])
          if key
            @data_store.delete(kind, key, data[:version])
            break
          end
        end
      else
        @config.logger.warn { "[LDClient] Unknown message received: #{method}" }
      end
    end

    def key_for_path(kind, path)
      path.start_with?(KEY_PATHS[kind]) ? path[KEY_PATHS[kind].length..-1] : nil
    end

    def log_connection_started
      @connection_attempt_start_time = Impl::Util::current_time_millis
    end

    def log_connection_result(is_success)
      if !@diagnostic_accumulator.nil? && @connection_attempt_start_time > 0
        @diagnostic_accumulator.record_stream_init(@connection_attempt_start_time, !is_success,
          Impl::Util::current_time_millis - @connection_attempt_start_time)
        @connection_attempt_start_time = 0
      end
    end
  end
end
