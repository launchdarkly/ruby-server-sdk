require "concurrent/atomics"
require "thread"

module LaunchDarkly
  class PollingProcessor
    def initialize(config, requestor)
      @config = config
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
      @config.logger.info { "[LDClient] Initializing polling connection" }
      create_worker
      @ready
    end

    def stop
      if @stopped.make_true
        if @worker && @worker.alive?
          @worker.raise "shutting down client"
        end
        @config.logger.info { "[LDClient] Polling connection stopped" }
      end
    end

    def poll
      all_data = @requestor.request_all_data
      if all_data
        @config.feature_store.init({
          FEATURES => all_data[:flags],
          SEGMENTS => all_data[:segments]
        })
        if @initialized.make_true
          @config.logger.info { "[LDClient] Polling connection initialized" }
          @ready.set
        end
      end
    end

    def create_worker
      @worker = Thread.new do
        @config.logger.debug { "[LDClient] Starting polling worker" }
        while !@stopped.value do
          begin
            started_at = Time.now
            poll
            delta = @config.poll_interval - (Time.now - started_at)
            if delta > 0
              sleep(delta)
            end
          rescue InvalidSDKKeyError
            @config.logger.error { "[LDClient] Received 401 error, no further polling requests will be made since SDK key is invalid" };
            @ready.set  # if client was waiting on us, make it stop waiting - has no effect if already set
            stop
          rescue StandardError => exn
            @config.logger.error { "[LDClient] Exception while polling: #{exn.inspect}" }
            # TODO: log_exception(__method__.to_s, exn)
          end
        end
      end
    end

    private :poll, :create_worker
  end
end
