require "concurrent/atomics"
require "json"
require "sse_client"

module LaunchDarkly
  # @private
  PUT = :put
  # @private
  PATCH = :patch
  # @private
  DELETE = :delete
  # @private
  INDIRECT_PUT = :'indirect/put'
  # @private
  INDIRECT_PATCH = :'indirect/patch'
  # @private
  READ_TIMEOUT_SECONDS = 300  # 5 minutes; the stream should send a ping every 3 minutes

  # @private
  KEY_PATHS = {
    FEATURES => "/flags/",
    SEGMENTS => "/segments/"
  }

  # @private
  class StreamProcessor
    def initialize(sdk_key, config, requestor)
      @sdk_key = sdk_key
      @config = config
      @feature_store = config.feature_store
      @requestor = requestor
      @initialized = Concurrent::AtomicBoolean.new(false)
      @started = Concurrent::AtomicBoolean.new(false)
      @stopped = Concurrent::AtomicBoolean.new(false)
      @ready = Concurrent::Event.new
    end

    def initialized?
      @initialized.value
    end

    def start
      return @ready unless @started.make_true

      @config.logger.info { "[LDClient] Initializing stream connection" }
      
      headers = {
        'Authorization' => @sdk_key,
        'User-Agent' => 'RubyClient/' + LaunchDarkly::VERSION
      }
      opts = {
        headers: headers,
        proxy: @config.proxy,
        read_timeout: READ_TIMEOUT_SECONDS,
        logger: @config.logger
      }
      @es = SSE::SSEClient.new(@config.stream_uri + "/all", opts) do |conn|
        conn.on_event { |event| process_message(event, event.type) }
        conn.on_error { |err|
          status = err[:status_code]
          message = Util.http_error_message(status, "streaming connection", "will retry")
          @config.logger.error { "[LDClient] #{message}" }
          if !Util.http_error_recoverable?(status)
            @ready.set  # if client was waiting on us, make it stop waiting - has no effect if already set
            stop
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

    def process_message(message, method)
      @config.logger.debug { "[LDClient] Stream received #{method} message: #{message.data}" }
      if method == PUT
        message = JSON.parse(message.data, symbolize_names: true)
        @feature_store.init({
          FEATURES => message[:data][:flags],
          SEGMENTS => message[:data][:segments]
        })
        @initialized.make_true
        @config.logger.info { "[LDClient] Stream initialized" }
        @ready.set
      elsif method == PATCH
        data = JSON.parse(message.data, symbolize_names: true)
        for kind in [FEATURES, SEGMENTS]
          key = key_for_path(kind, data[:path])
          if key
            @feature_store.upsert(kind, data[:data])
            break
          end
        end
      elsif method == DELETE
        data = JSON.parse(message.data, symbolize_names: true)
        for kind in [FEATURES, SEGMENTS]
          key = key_for_path(kind, data[:path])
          if key
            @feature_store.delete(kind, key, data[:version])
            break
          end
        end
      elsif method == INDIRECT_PUT
        all_data = @requestor.request_all_data
        @feature_store.init({
          FEATURES => all_data[:flags],
          SEGMENTS => all_data[:segments]
        })
        @initialized.make_true
        @config.logger.info { "[LDClient] Stream initialized (via indirect message)" }
      elsif method == INDIRECT_PATCH
        key = key_for_path(FEATURES, message.data)
        if key
          @feature_store.upsert(FEATURES, @requestor.request_flag(key))
        else
          key = key_for_path(SEGMENTS, message.data)
          if key
            @feature_store.upsert(SEGMENTS, @requestor.request_segment(key))
          end
        end
      else
        @config.logger.warn { "[LDClient] Unknown message received: #{method}" }
      end
    end

    def key_for_path(kind, path)
      path.start_with?(KEY_PATHS[kind]) ? path[KEY_PATHS[kind].length..-1] : nil
    end
  end
end
