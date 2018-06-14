require "concurrent/atomics"
require "json"
require "celluloid/eventsource"

module LaunchDarkly
  PUT = :put
  PATCH = :patch
  DELETE = :delete
  INDIRECT_PUT = :'indirect/put'
  INDIRECT_PATCH = :'indirect/patch'
  READ_TIMEOUT_SECONDS = 300  # 5 minutes; the stream should send a ping every 3 minutes

  KEY_PATHS = {
    FEATURES => "/flags/",
    SEGMENTS => "/segments/"
  }

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
      
      headers = 
      {
        'Authorization' => @sdk_key,
        'User-Agent' => 'RubyClient/' + LaunchDarkly::VERSION
      }
      opts = {:headers => headers, :with_credentials => true, :proxy => @config.proxy, :read_timeout => READ_TIMEOUT_SECONDS}
      @es = Celluloid::EventSource.new(@config.stream_uri + "/all", opts) do |conn|
        conn.on(PUT) { |message| process_message(message, PUT) }
        conn.on(PATCH) { |message| process_message(message, PATCH) }
        conn.on(DELETE) { |message| process_message(message, DELETE) }
        conn.on(INDIRECT_PUT) { |message| process_message(message, INDIRECT_PUT) }
        conn.on(INDIRECT_PATCH) { |message| process_message(message, INDIRECT_PATCH) }
        conn.on_error { |err|
          @config.logger.error { "[LDClient] Unexpected status code #{err[:status_code]} from streaming connection" }
          if err[:status_code] == 401
            @config.logger.error { "[LDClient] Received 401 error, no further streaming connection will be made since SDK key is invalid" }
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
        message = JSON.parse(message.data, symbolize_names: true)
        for kind in [FEATURES, SEGMENTS]
          key = key_for_path(kind, message[:path])
          if key
            @feature_store.upsert(kind, message[:data])
            break
          end
        end
      elsif method == DELETE
        message = JSON.parse(message.data, symbolize_names: true)
        for kind in [FEATURES, SEGMENTS]
          key = key_for_path(kind, message[:path])
          if key
            @feature_store.delete(kind, key, message[:version])
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
