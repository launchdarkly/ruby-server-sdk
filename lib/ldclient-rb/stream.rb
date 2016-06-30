require "concurrent/atomics"
require "json"
require "celluloid/eventsource"

module LaunchDarkly
  PUT = "put"
  PATCH = "patch"
  DELETE = "delete"

  class StreamProcessor
    def initialize(api_key, config)
      @api_key = api_key
      @config = config
      @store = config.feature_store ? config.feature_store : InMemoryFeatureStore.new
      @disconnected = Concurrent::AtomicReference.new(nil)
      @started = Concurrent::AtomicBoolean.new(false)
    end

    def initialized?
      @store.initialized?
    end

    def started?
      @started.value
    end

    def get_all_features
      if not initialized?
        throw :uninitialized
      end
      @store.all
    end

    def get_feature(key)
      if not initialized?
        throw :uninitialized
      end
      @store.get(key)
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
        conn.on_open do
          set_connected
        end

        conn.on(PUT) { |message| process_message(message, PUT) }
        conn.on(PATCH) { |message| process_message(message, PATCH) }
        conn.on(DELETE) { |message| process_message(message, DELETE) }

        conn.on_error do |message|
          # TODO replace this with proper logging
          @config.logger.error("[LDClient] Error connecting to stream. Status code: #{message[:status_code]}")
          set_disconnected
        end
      end
    end

    def process_message(message, method)
      message = JSON.parse(message.data, symbolize_names: true)
      if method == PUT
        @store.init(message)
      elsif method == PATCH
        @store.upsert(message[:path][1..-1], message[:data])
      elsif method == DELETE
        @store.delete(message[:path][1..-1], message[:version])
      else
        @config.logger.error("[LDClient] Unknown message received: #{method}")
      end
      set_connected
    end

    def set_disconnected
      @disconnected.set(Time.now)
    end

    def set_connected
      @disconnected.set(nil)
    end

    def should_fallback_update
      disc = @disconnected.get
      !disc.nil? && disc < (Time.now - 120)
    end

    # TODO mark private methods
    private :process_message, :set_connected, :set_disconnected
  end
end
