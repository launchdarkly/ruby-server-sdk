require "concurrent/atomics"
require "thread"

module LaunchDarkly
  # @private
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
        if @worker && @worker.alive? && @worker != Thread.current
          @worker.run  # causes the thread to wake up if it's currently in a sleep
          @worker.join
        end
        @config.logger.info { "[LDClient] Polling connection stopped" }
      end
    end

    def poll
      all_data = @requestor.request_all_data
      if all_data
        @config.feature_store.init(all_data)
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
          started_at = Time.now
          begin
            poll
          rescue UnexpectedResponseError => e
            message = Util.http_error_message(e.status, "polling request", "will retry")
            @config.logger.error { "[LDClient] #{message}" };
            if !Util.http_error_recoverable?(e.status)
              @ready.set  # if client was waiting on us, make it stop waiting - has no effect if already set
              stop
            end
          rescue StandardError => exn
            Util.log_exception(@config.logger, "Exception while polling", exn)
          end
          delta = @config.poll_interval - (Time.now - started_at)
          if delta > 0
            sleep(delta)
          end
        end
      end
    end

    private :poll, :create_worker
  end
end
