require "concurrent/atomics"

module LaunchDarkly
  class PollingProcessor
    
    def initialize(config, requestor)
      @config = config
      @requestor = requestor
      @initalized = Concurrent::AtomicBoolean.new(false)
      @started = Concurrent::AtomicBoolean.new(false)
    end

    def initialized?
      @initialized.value
    end

    def start
      return unless @started.make_true
      @config.logger.info("[LDClient] Initializing polling connection")

      create_worker
    end

    def poll
      flags = @requestor.request_all_flags
      if flags
        @config.store.init(flags)
        if @initialized.make_true
          @config.logger.info("[LDClient] Polling connection initialized")
        else
          @config.logger.debug("[LDClient] Received polling updated")
        end
      end
    end

    def create_worker
      Thread.new do
        loop do
          begin
            started_at = Time.now
            poll
            delta = @config.poll_interval - (Time.now - started_at)
            if delta > 0
              sleep(delta)
            end
          rescue StandardError => exn
           # TODO: log_exception(__method__.to_s, exn)
          end
        end
      end
    end


    private :poll, :create_worker
  end
end