require "concurrent/atomics"
require "json"
require "celluloid/eventsource"

module LaunchDarkly
  PUT = "put"
  PATCH = "patch"
  DELETE = "delete"
  INDIRECT_PUT = "indirect/put"
  INDIRECT_PATCH = "indirect/patch"

  class StreamProcessor
    def initialize(api_key, config, requestor)
      @api_key = api_key
      @config = config
      @store = config.feature_store ? config.feature_store : InMemoryFeatureStore.new
      @requestor = requestor
      @initialized = Concurrent::AtomicBoolean.new(false)
      @started = Concurrent::AtomicBoolean.new(false)
    end

    def initialized?
      @initialized.value
    end

    def start
      return unless @started.make_true
      
      headers = 
      {
        'Authorization' => 'api_key ' + @api_key,
        'User-Agent' => 'RubyClient/' + LaunchDarkly::VERSION
      }
      opts = {:headers => headers, :with_credentials => true}
      @es = Celluloid::EventSource.new(@config.stream_uri + "/features", opts) do |conn|
        conn.on(PUT) { |message| process_message(message, PUT) }
        conn.on(PATCH) { |message| process_message(message, PATCH) }
        conn.on(DELETE) { |message| process_message(message, DELETE) }
        conn.on(INDIRECT_PUT) { |message| process_message(message, INDIRECT_PUT) }
        conn.on(INDIRECT_PATCH) { |message| process_message(message, INDIRECT_PATCH) }
        conn.on_error do |message|
          @config.logger.error("[LDClient] Error connecting to stream. Status code: #{message[:status_code]}")
        end
      end
    end

    def process_message(message, method)
      message = JSON.parse(message.data, symbolize_names: true)
      @config.logger.debug("[LDClient] Stream received #{method} message")
      if method == PUT
        @store.init(message)
        @initialized.make_true
        @config.logger.debug("[LDClient] Stream initialized")
      elsif method == PATCH
        @store.upsert(message[:path][1..-1], message[:data])
      elsif method == DELETE
        @store.delete(message[:path][1..-1], message[:version])
      elsif method == INDIRECT_PUT
        @store.init(@requestor.request_all_flags)
        @initialized.make_true
        @config.logger.debug("[LDClient] Stream initialized (via indirect message)")
      elsif method == INDIRECT_PATCH
        @store.upsert(@requestor.request_flag(message[:data]))        
      else
        @config.logger.error("[LDClient] Unknown message received: #{method}")
      end
    end

    private :process_message
  end
end
