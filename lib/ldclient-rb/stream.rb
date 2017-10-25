require "concurrent/atomics"
require "json"
require "celluloid/eventsource"

module LaunchDarkly
  PUT = :put
  PATCH = :patch
  DELETE = :delete
  INDIRECT_PUT = :'indirect/put'
  INDIRECT_PATCH = :'indirect/patch'

  class StreamProcessor
    def initialize(sdk_key, config, requestor)
      @sdk_key = sdk_key
      @config = config
      @store = config.feature_store
      @requestor = requestor
      @initialized = Concurrent::AtomicBoolean.new(false)
      @started = Concurrent::AtomicBoolean.new(false)
      @stopped = Concurrent::AtomicBoolean.new(false)
    end

    def initialized?
      @initialized.value
    end

    def start
      return unless @started.make_true

      @config.logger.info("[LDClient] Initializing stream connection")
      
      headers = 
      {
        'Authorization' => @sdk_key,
        'User-Agent' => 'RubyClient/' + LaunchDarkly::VERSION
      }
      opts = {:headers => headers, :with_credentials => true, :proxy => @config.proxy}
      @es = Celluloid::EventSource.new(@config.stream_uri + "/flags", opts) do |conn|
        conn.on(PUT) { |message| process_message(message, PUT) }
        conn.on(PATCH) { |message| process_message(message, PATCH) }
        conn.on(DELETE) { |message| process_message(message, DELETE) }
        conn.on(INDIRECT_PUT) { |message| process_message(message, INDIRECT_PUT) }
        conn.on(INDIRECT_PATCH) { |message| process_message(message, INDIRECT_PATCH) }
      end
    end

    def stop
      if @stopped.make_true
        @es.close
        @config.logger.info("[LDClient] Stream connection stopped")
      end
    end

    def process_message(message, method)
      @config.logger.debug("[LDClient] Stream received #{method} message: #{message.data}")
      if method == PUT
        message = JSON.parse(message.data, symbolize_names: true)
        @store.init(message)
        @initialized.make_true
        @config.logger.info("[LDClient] Stream initialized")
      elsif method == PATCH
        message = JSON.parse(message.data, symbolize_names: true)
        @store.upsert(message[:path][1..-1], message[:data])
      elsif method == DELETE
        message = JSON.parse(message.data, symbolize_names: true)
        @store.delete(message[:path][1..-1], message[:version])
      elsif method == INDIRECT_PUT
        @store.init(@requestor.request_all_flags)
        @initialized.make_true
        @config.logger.info("[LDClient] Stream initialized (via indirect message)")
      elsif method == INDIRECT_PATCH
        @store.upsert(message.data, @requestor.request_flag(message.data))
      else
        @config.logger.warn("[LDClient] Unknown message received: #{method}")
      end
    end

    private :process_message
  end
end
