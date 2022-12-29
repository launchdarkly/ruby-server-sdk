require "ldclient-rb/impl/repeating_task"

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
      @ready = Concurrent::Event.new
      @task = Impl::RepeatingTask.new(@config.poll_interval, 0, -> { self.poll }, @config.logger)
    end

    def initialized?
      @initialized.value
    end

    def start
      return @ready unless @started.make_true
      @config.logger.info { "[LDClient] Initializing polling connection" }
      @task.start
      @ready
    end

    def stop
      @task.stop
      @config.logger.info { "[LDClient] Polling connection stopped" }
    end

    def poll
      begin
        all_data = @requestor.request_all_data
        if all_data
          @config.feature_store.init(all_data)
          if @initialized.make_true
            @config.logger.info { "[LDClient] Polling connection initialized" }
            @ready.set
          end
        end
      rescue UnexpectedResponseError => e
        message = Util.http_error_message(e.status, "polling request", "will retry")
        @config.logger.error { "[LDClient] #{message}" }
        unless Util.http_error_recoverable?(e.status)
          @ready.set  # if client was waiting on us, make it stop waiting - has no effect if already set
          stop
        end
      rescue StandardError => e
        Util.log_exception(@config.logger, "Exception while polling", e)
      end
    end
  end
end
