require "concurrent/atomics"
require "concurrent/timer_task"

require "json"

module LaunchDarkly
  PUT = 'put'
  PATCH = 'patch'
  DELETE = 'delete'
  INDIRECT_PUT = 'indirect/put'
  INDIRECT_PATCH = 'indirect/patch'
  READ_TIMEOUT_SECONDS = 50 * 6  # 5 minutes; the stream should send a ping every 3 minutes

  KEY_PATHS = {
    FEATURES => "/flags/",
    SEGMENTS => "/segments/"
  }

  class StreamProcessor
    def initialize(sdk_key, config, requestor)
      @sdk_key = sdk_key
      @config = config
      @feature_store = config.feature_store
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

      # The TimerTask has a nice property - it will not spool up a subsequent execution of a task if a previous one hasn't completed
      @task = Concurrent::TimerTask.execute(:execution_interval => READ_TIMEOUT_SECONDS) do |task|
        @config.logger.info { "[LDClient] Initializing stream connection withih a TimerTask" }
        headers = {
          'Authorization' => @sdk_key,
          'User-Agent' => 'RubyClient/' + LaunchDarkly::VERSION
        }
        listener = LaunchDarkly::EventSourceListener.new(@config.stream_uri + "/all", :headers => headers, :via => @config.proxy, :read_timeout => READ_TIMEOUT_SECONDS)
        listener.on(PUT) { |message| process_message(message, PUT) }
        listener.on(PATCH) { |message| process_message(message, PATCH) }
        listener.on(DELETE) { |message| process_message(message, DELETE) }
        listener.on(INDIRECT_PUT) { |message| process_message(message, INDIRECT_PUT) }
        listener.on(INDIRECT_PATCH) { |message| process_message(message, INDIRECT_PATCH) }
        listener.on_error do |err|
          @config.logger.error { "[LDClient] Unexpected status code #{err[:status_code]} from streaming connection" }
          if err[:status_code] == 401
            @config.logger.error { "[LDClient] Received 401 error, no further streaming connection will be made since SDK key is invalid" }
            stop
          end
        end
        listener.start
      end
    end

    def stop
      if @stopped.make_true
        @task.shutdown
        @config.logger.info { "[LDClient] Stream connection stopped" }
      end
    end

    private

    def process_message(message, method)
      @config.logger.debug {"[LDClient] Stream received #{method} message: #{message.data}" }
      if method == PUT
        message = JSON.parse(message.data, :symbolize_names => true)
        @feature_store.init({
          FEATURES => message[:data][:flags],
          SEGMENTS => message[:data][:segments]
        })
        @initialized.make_true
        @config.logger.info { "[LDClient] Stream initialized" }
      elsif method == PATCH
        message = JSON.parse(message.data, :symbolize_names => true)
        for kind in [FEATURES, SEGMENTS]
          key = key_for_path(kind, message[:path])
          if key
            @feature_store.upsert(kind, message[:data])
            break
          end
        end
      elsif method == DELETE
        message = JSON.parse(message.data, :symbolize_names => true)
        for kind in [FEATURES, SEGMENTS]
          key = key_for_path(kind, message[:path])
          if key
            @feature_store.delete(kind, key, message[:version])
            break
          end
        end
      elsif method == INDIRECT_PUT
        all_data = @requestor.request_all_data
        @feature_store.init({
          FEATURES => all_data[:flags],
          SEGMENTS => all_data[:segments]
        })
        @initialized.make_true
        @config.logger.info {"[LDClient] Stream initialized (via indirect message)" }
      elsif method == INDIRECT_PATCH
        key = key_for_path(FEATURES, message.data)
        if key
          @feature_store.upsert(FEATURES, @requestor.request_flag(key))
        else
          key = key_for_path(SEGMENTS, message.data)
          if key
            @feature_store.upsert(SEGMENTS, @requestor.request_segment(key))
          end
        end
      else
        @config.logger.warn { "[LDClient] Unknown message received: #{method}" }
      end
    end

    def key_for_path(kind, path)
      path.start_with?(KEY_PATHS[kind]) ? path[KEY_PATHS[kind].length..-1] : nil
    end
  end
end
