require 'celluloid/eventsource'
require 'concurrent/atomics'
require 'json'

module LaunchDarkly

  PUT_FEATURE = "put/features"
  PATCH_FEATURE = "patch/features"
  DELETE_FEATURE = "delete/features"

  class InMemoryFeatureStore
    def initialize()
      @features = Hash.new
      @lock = Concurrent::ReadWriteLock.new
      @initialized = Concurrent::AtomicBoolean.new(false)
    end

    def get(key)
      @lock.with_read_lock {
        f = @features[key.to_sym]
        f[:deleted] ? nil : f
      }
    end

    def all()
      @lock.with_read_lock {
        @features.select {|k,f| not f[:deleted]}  
      }
    end

    def delete(key, version)
      @lock.with_write_lock {
        old = @features[key.to_sym]

        if old != nil and old[:version] < version
          old[:deleted] = true
          old[:version] = version
          @features[key.to_sym] = old
        elsif old == nil
          @features[key.to_sym] = {:deleted => true, :version => version}
        end
      }
    end

    def init(fs)
      @lock.with_write_lock {
        @features.replace(fs)
        @initialized.make_true
      }
    end

    def upsert(key, feature)
      @lock.with_write_lock {
        old = @features[key.to_sym]

        if old == nil or old[:version] < feature[:version]
          @features[key.to_sym] = feature
        end
      }
    end

    def initialized?()
      @initialized.value
    end    
  end

  class StreamProcessor
    def initialize(api_key, config)
      @api_key = api_key
      @config = config
      @store = config.feature_store ? config.feature_store : InMemoryFeatureStore.new
      @disconnected = Concurrent::AtomicReference.new(nil)
    end

    def initialized?()
      @store.initialized?
    end

    def get_feature(key)
      if not initialized?
        throw :uninitialized
      end
      @store.get(key)
    end

    def subscribe()
      headers = 
      {
        'Authorization' => 'api_key ' + @api_key,
        'User-Agent' => 'RubyClient/' + LaunchDarkly::VERSION
      }
      opts = {:headers => headers, :with_credentials => true}
      @es = Celluloid::EventSource.new(@config.stream_uri + "/", opts) do |conn|
        conn.on_open do
          set_connected
        end

        conn.on_error do |message|
          puts "Error message #{message[:status_code]}, Response body #{message[:body]}"
          set_disconnected
        end

        conn.on(PUT_FEATURE) do |event|
          features = JSON.parse(event.data, :symbolize_names => true)
          @store.init(features)
          set_connected
        end

        conn.on(PATCH_FEATURE) do |event|
          json = JSON.parse(event.data, :symbolize_names => true)
          @store.upsert(json[:path][1..-1], json[:data])
          set_connected
        end

        conn.on(DELETE_FEATURE) do |event|
          json = JSON.parse(event.data, :symbolize_names => true)
          @store.delete(json[:path][1..-1], json[:version])
          set_connected
        end
      end
    end

    def set_disconnected()
      @disconnected.set(Time.now)
    end

    def set_connected()
      @disconnected.set(nil)
    end

    def should_fallback_update()
      disc = @disconnected.get
      disc != nil and disc < (Time.now - 120)
    end

    # TODO mark private methods

  end

end