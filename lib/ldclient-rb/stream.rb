require "concurrent/atomics"
require "json"
require "celluloid/eventsource"

module LaunchDarkly
  PUT = "put"
  PATCH = "patch"
  DELETE = "delete"

  class InMemoryFeatureStore
    def initialize
      @features = Hash.new
      @lock = Concurrent::ReadWriteLock.new
      @initialized = Concurrent::AtomicBoolean.new(false)
    end

    def get(key)
      @lock.with_read_lock do
        f = @features[key.to_sym]
        (f.nil? || f[:deleted]) ? nil : f
      end
    end

    def all
      @lock.with_read_lock do
        @features.select { |_k, f| not f[:deleted] }
      end
    end

    def delete(key, version)
      @lock.with_write_lock do
        old = @features[key.to_sym]

        if !old.nil? && old[:version] < version
          old[:deleted] = true
          old[:version] = version
          @features[key.to_sym] = old
        elsif old.nil?
          @features[key.to_sym] = { deleted: true, version: version }
        end
      end
    end

    def init(fs)
      @lock.with_write_lock do
        @features.replace(fs)
        @initialized.make_true
      end
    end

    def upsert(key, feature)
      @lock.with_write_lock do
        old = @features[key.to_sym]

        if old.nil? || old[:version] < feature[:version]
          @features[key.to_sym] = feature
        end
      end
    end

    def initialized?
      @initialized.value
    end
  end

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
          @config.logger.error("[LDClient] Error message #{message[:status_code]}, Response body #{message[:body]}")
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
