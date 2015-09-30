require 'concurrent/atomics'
require 'json'
require 'ld-em-eventsource'

module LaunchDarkly

  PUT = "put"
  PATCH = "patch"
  DELETE = "delete"

  class InMemoryFeatureStore
    def initialize()
      @features = Hash.new
      @lock = Concurrent::ReadWriteLock.new
      @initialized = Concurrent::AtomicBoolean.new(false)
    end

    def get(key)
      @lock.with_read_lock {
        f = @features[key.to_sym]
        (f.nil? || f[:deleted]) ? nil : f
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
        elsif old.nil?
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

        if old.nil? or old[:version] < feature[:version]
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
      @started = Concurrent::AtomicBoolean.new(false)
    end

    def initialized?()
      @store.initialized?
    end

    def started?()
      @started.value
    end

    def get_feature(key)
      if not initialized?
        throw :uninitialized
      end
      @store.get(key)
    end

    def start_reactor()
      if defined?(Thin)
        @config.logger.debug("Running in a Thin environment-- not starting EventMachine")
      elsif EM.reactor_running?
        @config.logger.debug("EventMachine already running")
      else
        @config.logger.debug("Starting EventMachine")
        Thread.new { EM.run {} }
        Thread.pass until EM.reactor_running?
      end
      EM.reactor_running?
    end

    def start()
      # Try to start the reactor. If it's not started, we shouldn't start
      # the stream processor
      if not start_reactor
        return
      end

      # If someone else booted the stream processor connection, just return
      if not @started.make_true
        return
      end

      # If we're the first and only thread to set started, boot
      # the stream processor connection
      EM.defer do
        source = EM::EventSource.new(@config.stream_uri + "/features",
                                    {},
                                    {'Accept' => 'text/event-stream',
                                     'Authorization' => 'api_key ' + @api_key,
                                     'User-Agent' => 'RubyClient/' + LaunchDarkly::VERSION})
        source.on PUT do |message|
          features = JSON.parse(message, :symbolize_names => true)
          @store.init(features)
          set_connected
        end
        source.on PATCH do |message|
          json = JSON.parse(message, :symbolize_names => true)
          @store.upsert(json[:path][1..-1], json[:data])
          set_connected
        end
        source.on DELETE do |message|
          json = JSON.parse(message, :symbolize_names => true)
          @store.delete(json[:path][1..-1], json[:version])
          set_connected
        end
        source.error do |error|
          @config.logger.error("[LDClient] Error subscribing to stream API: #{error}")
          set_disconnected
        end
        source.inactivity_timeout = 0
        source.start
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
    private :set_connected, :set_disconnected, :start_reactor

  end

end
