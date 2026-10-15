require "ldclient-rb/impl/data_source/stream"
require "ld-eventsource"
require "model_builders"
require "spec_helper"
require "http_util"

module LaunchDarkly
  describe Impl::DataSource::StreamProcessor do
    subject { Impl::DataSource::StreamProcessor }
    let(:executor) { SynchronousExecutor.new }
    let(:status_broadcaster) { Impl::Broadcaster.new(executor, $null_log) }
    let(:flag_change_broadcaster) { Impl::Broadcaster.new(executor, $null_log) }
    let(:config) {
      config = Config.new
      config.data_source_update_sink = Impl::DataSource::UpdateSink.new(config.feature_store, status_broadcaster, flag_change_broadcaster)
      config.data_source_update_sink.update_status(Interfaces::DataSource::Status::VALID, nil)
      config
    }
    let(:processor) { subject.new("sdk_key", config) }

    describe '#process_message' do
      let(:put_message) { SSE::StreamEvent.new(:put, '{"data":{"flags":{"asdf": {"key": "asdf"}},"segments":{"segkey": {"key": "segkey"}}}}') }
      let(:patch_flag_message) { SSE::StreamEvent.new(:patch, '{"path": "/flags/key", "data": {"key": "asdf", "version": 1}}') }
      let(:patch_seg_message) { SSE::StreamEvent.new(:patch, '{"path": "/segments/key", "data": {"key": "asdf", "version": 1}}') }
      let(:delete_flag_message) { SSE::StreamEvent.new(:delete, '{"path": "/flags/key", "version": 2}') }
      let(:delete_seg_message) { SSE::StreamEvent.new(:delete, '{"path": "/segments/key", "version": 2}') }
      let(:invalid_message) { SSE::StreamEvent.new(:put, '{Hi there}') }

      it "will accept PUT methods" do
        processor.send(:process_message, put_message)
        expect(config.feature_store.get(Impl::DataStore::FEATURES, "asdf")).to eq(Flags.from_hash(key: "asdf"))
        expect(config.feature_store.get(Impl::DataStore::SEGMENTS, "segkey")).to eq(Segments.from_hash(key: "segkey"))
      end
      it "will accept PATCH methods for flags" do
        processor.send(:process_message, patch_flag_message)
        expect(config.feature_store.get(Impl::DataStore::FEATURES, "asdf")).to eq(Flags.from_hash(key: "asdf", version: 1))
      end
      it "will accept PATCH methods for segments" do
        processor.send(:process_message, patch_seg_message)
        expect(config.feature_store.get(Impl::DataStore::SEGMENTS, "asdf")).to eq(Segments.from_hash(key: "asdf", version: 1))
      end
      it "will accept DELETE methods for flags" do
        processor.send(:process_message, patch_flag_message)
        processor.send(:process_message, delete_flag_message)
        expect(config.feature_store.get(Impl::DataStore::FEATURES, "key")).to eq(nil)
      end
      it "will accept DELETE methods for segments" do
        processor.send(:process_message, patch_seg_message)
        processor.send(:process_message, delete_seg_message)
        expect(config.feature_store.get(Impl::DataStore::SEGMENTS, "key")).to eq(nil)
      end
      it "will log a warning if the method is not recognized" do
        expect(processor.instance_variable_get(:@config).logger).to receive :warn
        processor.send(:process_message, SSE::StreamEvent.new(type: :get, data: "", id: nil))
      end
      it "raises for invalid JSON and leaves the status to the error handler" do
        listener = ListenerSpy.new
        status_broadcaster.add_listener(listener)

        expect { processor.send(:process_message, invalid_message) }.to raise_error(JSON::ParserError)
        expect(listener.statuses.map(&:state)).not_to include(Interfaces::DataSource::Status::INTERRUPTED)
      end
    end

    # Replaces the SSE client with a double, and yields the handlers the processor registers on it.
    def with_handlers(processor, sse_client = double("SSE::Client", close: nil))
      handlers = {}
      connection = double("connection")
      %i[on_connect on_event on_error].each do |name|
        allow(connection).to receive(name) { |&block| handlers[name] = block }
      end
      allow(SSE::Client).to receive(:new) do |_uri, **opts, &block|
        handlers[:opts] = opts
        block.call(connection)
        sse_client
      end

      processor.start
      begin
        yield handlers, sse_client
      ensure
        processor.stop
      end
    end

    describe 'environment ID' do
      it 'is recorded from the connection response headers' do
        with_handlers(processor) do |handlers|
          handlers[:on_connect].call({ "X-LD-EnvID" => "env-abc" })
          expect(config.data_source_update_sink.environment_id).to eq("env-abc")
        end
      end

      it 'is not recorded when the header is absent' do
        with_handlers(processor) do |handlers|
          handlers[:on_connect].call({})
          expect(config.data_source_update_sink.environment_id).to be_nil
        end
      end
    end

    describe 'retry' do
      let(:put_message) { SSE::StreamEvent.new(:put, '{"data":{"flags":{},"segments":{}}}') }
      let(:listener) { ListenerSpy.new }
      let(:logger) { double("logger").as_null_object }
      let(:config) {
        config = Config.new(logger: logger)
        config.data_source_update_sink = Impl::DataSource::UpdateSink.new(config.feature_store, status_broadcaster, flag_change_broadcaster)
        config.data_source_update_sink.update_status(Interfaces::DataSource::Status::VALID, nil)
        status_broadcaster.add_listener(listener)
        config
      }
      # Delays short enough that a failure handler returns at once.
      let(:fast_retry_state) {
        Impl::RetryState.new(normal_initial_delay: 0.001, normal_ceiling_delay: 0.001, extended_initial_delay: 0.002,
          extended_ceiling_delay: 0.002, reset_policy: Impl::RetryState::AfterConsecutiveSuccesses.new(2))
      }

      def use_fast_retry_state
        allow(Impl::RetryState).to receive(:for_streaming).and_return(fast_retry_state)
      end

      def http_error(status)
        SSE::Errors::HTTPStatusError.new(status, "")
      end

      def states
        listener.statuses.map(&:state)
      end

      it 'passes an Integer zero reconnect time to the SSE client' do
        with_handlers(processor) do |handlers|
          expect(handlers[:opts][:reconnect_time]).to eql(0)
        end
      end

      [401, 403, 404].each do |status|
        it "keeps retrying after error #{status}" do
          use_fast_retry_state
          with_handlers(processor) do |handlers, sse_client|
            3.times { handlers[:on_error].call(http_error(status)) }

            expect(sse_client).not_to have_received(:close)
            expect(states).to eq([Interfaces::DataSource::Status::INTERRUPTED] * 3)
            expect(listener.statuses.last.last_error.status_code).to eq(status)
            expect(processor.instance_variable_get(:@ready).set?).to be false
          end
        end
      end

      it 'waits in the extended regime after an unexpected error' do
        with_handlers(processor) do |handlers|
          waiter = Thread.new { handlers[:on_error].call(http_error(401)) }
          begin
            expect(waiter.join(0.2)).to be_nil
            expect(processor.instance_variable_get(:@retry_state).next_delay).to be_between(150, 300)
            expect(states).to eq([Interfaces::DataSource::Status::INTERRUPTED])
          ensure
            processor.stop
            waiter.join(1)
          end
        end
      end

      it 'ends a long wait at once when stopped' do
        with_handlers(processor) do |handlers|
          waiter = Thread.new { handlers[:on_error].call(http_error(401)) }
          expect(waiter.join(0.2)).to be_nil

          started_at = Time.now
          processor.stop
          expect(waiter.join(1)).not_to be_nil
          expect(Time.now - started_at).to be < 1
          expect(states.last).to eq(Interfaces::DataSource::Status::OFF)
        end
      end

      it 'waits the normal delay after a recoverable error' do
        with_handlers(processor) do |handlers|
          waiter = Thread.new { handlers[:on_error].call(http_error(503)) }
          begin
            expect(waiter.join(0.2)).to be_nil
            expect(processor.instance_variable_get(:@retry_state).next_delay).to be_between(0.5, 1)
          ensure
            processor.stop
            waiter.join(1)
          end
        end
      end

      it 'backs off and warns when the server closes the stream' do
        use_fast_retry_state
        expect(logger).to receive(:warn) do |&block|
          expect(block.call).to match(/server closed the streaming connection - will retry in 0\.0s/)
        end
        expect(fast_retry_state).to receive(:record_failure).with(:normal).and_call_original

        with_handlers(processor) do |handlers|
          handlers[:on_error].call(SSE::Errors::StreamClosedByServerError.new)
          expect(states).to eq([Interfaces::DataSource::Status::INTERRUPTED])
          expect(listener.statuses.last.last_error.kind).to eq(Interfaces::DataSource::ErrorInfo::NETWORK_ERROR)
        end
      end

      [
        ["error 401", -> { SSE::Errors::HTTPStatusError.new(401, "") }, :error,
          "[LDClient] HTTP error 401 (invalid SDK key) for streaming connection - will retry in 0.3s"],
        ["error 503", -> { SSE::Errors::HTTPStatusError.new(503, "") }, :warn,
          "[LDClient] HTTP error 503 for streaming connection - will retry in 0.0s"],
        ["invalid data", -> { JSON::ParserError.new("bad") }, :error,
          "[LDClient] Invalid data on streaming connection: bad - will retry in 0.0s"],
        ["a server close", -> { SSE::Errors::StreamClosedByServerError.new }, :warn,
          "[LDClient] The server closed the streaming connection - will retry in 0.0s"],
        ["another error", -> { StandardError.new("boom") }, :warn,
          "[LDClient] Error on streaming connection: boom - will retry in 0.0s"],
      ].each do |desc, make_error, level, message|
        it "logs #{desc} once at #{level}, with the delay" do
          allow(Impl::RetryState).to receive(:for_streaming).and_return(
            Impl::RetryState.new(normal_initial_delay: 0.001, normal_ceiling_delay: 0.001, extended_initial_delay: 0.3,
              extended_ceiling_delay: 0.3, reset_policy: Impl::RetryState::AfterConsecutiveSuccesses.new(2),
              random: double("random", rand: 0.0)))
          logs = []
          %i[error warn].each do |name|
            allow(logger).to receive(name) { |&block| logs << [name, block.call] }
          end

          with_handlers(processor) do |handlers|
            handlers[:on_error].call(make_error.call)
          end
          expect(logs).to eq([[level, message]])
        end
      end

      it 'resets to the normal regime 60 seconds after the first healthy event that follows a failure' do
        now = 0.0
        retry_state = Impl::RetryState.for_streaming(1, logger, clock: -> { now }, random: double("random", rand: 0.0))
        allow(Impl::RetryState).to receive(:for_streaming).and_return(retry_state)
        retry_state.record_failure(:unexpected)

        with_handlers(processor) do |handlers|
          handlers[:on_connect].call({})
          handlers[:on_event].call(put_message)
          now += 30
          handlers[:on_event].call(put_message)
          now += 30

          waiter = Thread.new { handlers[:on_error].call(http_error(503)) }
          begin
            expect(waiter.join(0.2)).to be_nil
            expect(retry_state.next_delay).to eq(1)
          ensure
            processor.stop
            waiter.join(1)
          end
        end
      end

      it 'does not record a success for an event that fails' do
        use_fast_retry_state
        expect(fast_retry_state).not_to receive(:record_success)

        with_handlers(processor) do |handlers|
          handlers[:on_connect].call({})
          expect { handlers[:on_event].call(SSE::StreamEvent.new(:put, '{Hi there}')) }.to raise_error(JSON::ParserError)
        end
      end

      it 'does not report a status after OFF from a handler that is already running' do
        use_fast_retry_state
        with_handlers(processor) do |handlers|
          # The handler passed its stopped check just before stop reported OFF.
          config.data_source_update_sink.update_status(Interfaces::DataSource::Status::OFF, nil)
          handlers[:on_error].call(http_error(503))
          handlers[:on_error].call(SSE::Errors::StreamClosedByServerError.new)

          expect(states).to eq([Interfaces::DataSource::Status::OFF])
        end
      end

      # A retry state with a fixed normal delay and no jitter.
      def retry_state_with_delay(delay)
        Impl::RetryState.new(normal_initial_delay: delay, normal_ceiling_delay: delay, extended_initial_delay: delay,
          extended_ceiling_delay: delay, reset_policy: Impl::RetryState::AfterConsecutiveSuccesses.new(2),
          random: double("random", rand: 0.0))
      end

      # Sends an event the way the SSE client does: an error raised by the handler goes to on_error.
      def deliver_event(handlers, event)
        handlers[:on_event].call(event)
      rescue StandardError => e
        handlers[:on_error].call(e)
      end

      it 'reports invalid data as one failure, one INVALID_DATA status and one wait' do
        use_fast_retry_state
        expect(fast_retry_state).to receive(:record_failure).once.with(:normal).and_call_original
        expect(processor.instance_variable_get(:@stop_event)).to receive(:wait).once.and_call_original

        with_handlers(processor) do |handlers|
          handlers[:on_connect].call({})
          deliver_event(handlers, SSE::StreamEvent.new(:put, '{Hi there}'))

          expect(states).to eq([Interfaces::DataSource::Status::INTERRUPTED])
          expect(listener.statuses.last.last_error.kind).to eq(Interfaces::DataSource::ErrorInfo::INVALID_DATA)
        end
      end

      it 'waits the recorded delay before it reconnects after invalid data' do
        allow(Impl::RetryState).to receive(:for_streaming).and_return(retry_state_with_delay(0.2))

        with_handlers(processor) do |handlers|
          started_at = Time.now
          deliver_event(handlers, SSE::StreamEvent.new(:put, '{Hi there}'))
          expect(Time.now - started_at).to be >= 0.15
        end
      end

      it 'does not count an unknown event type as healthy' do
        use_fast_retry_state
        expect(fast_retry_state).not_to receive(:record_success)

        with_handlers(processor) do |handlers|
          handlers[:on_connect].call({})
          handlers[:on_event].call(SSE::StreamEvent.new(:unknown, "{}"))
        end
      end

      it 'waits before it reconnects even if reporting the failure raises' do
        allow(Impl::RetryState).to receive(:for_streaming).and_return(retry_state_with_delay(0.2))
        sink = config.data_source_update_sink
        allow(sink).to receive(:update_status).and_call_original
        allow(sink).to receive(:update_status).with(Interfaces::DataSource::Status::INTERRUPTED, anything)
          .and_raise(StandardError.new("sink failure"))

        with_handlers(processor) do |handlers|
          started_at = Time.now
          expect { handlers[:on_error].call(http_error(503)) }.to raise_error(StandardError, "sink failure")
          expect(Time.now - started_at).to be >= 0.15
        end
      end

      it 'can be stopped before it is started' do
        expect { processor.stop }.not_to raise_error
        expect(states).to eq([Interfaces::DataSource::Status::OFF])
        expect(logger).not_to have_received(:error)
      end

      it 'closes the SSE client at once if it was stopped before the client existed' do
        processor.stop
        with_handlers(processor) do |_handlers, sse_client|
          expect(sse_client).to have_received(:close)
        end
      end

      it 'reports OFF and wakes a waiting handler when closing the SSE client raises' do
        sse_client = double("SSE::Client")
        allow(sse_client).to receive(:close).and_raise(IOError.new("close failure"))

        with_handlers(processor, sse_client) do |handlers|
          waiter = Thread.new { handlers[:on_error].call(http_error(401)) }
          expect(waiter.join(0.2)).to be_nil

          expect { processor.stop }.not_to raise_error
          expect(waiter.join(1)).not_to be_nil
          expect(states.last).to eq(Interfaces::DataSource::Status::OFF)
        end
      end

      it 'does not report a status or wait after it is stopped' do
        with_handlers(processor) do |handlers|
          processor.stop
          started_at = Time.now
          handlers[:on_error].call(http_error(401))
          handlers[:on_error].call(SSE::Errors::StreamClosedByServerError.new)

          expect(Time.now - started_at).to be < 1
          expect(states).to eq([Interfaces::DataSource::Status::OFF])
        end
      end
    end

    describe 'with a real SSE client' do
      # The SSE worker thread can log after the example ends, so this cannot be a test double.
      let(:logger) { $null_log }

      # Not a test double, because the SSE worker thread can use it after the example ends.
      let(:no_jitter) { Object.new.tap { |r| r.define_singleton_method(:rand) { 0.0 } } }

      # Starts a processor against a server that answers every stream request with 503, and yields the
      # processor, the times at which the requests arrived, and the SSE worker thread.
      def with_failing_stream(retry_delay)
        allow(Impl::RetryState).to receive(:for_streaming).and_return(
          Impl::RetryState.new(normal_initial_delay: retry_delay, normal_ceiling_delay: retry_delay,
            extended_initial_delay: retry_delay, extended_ceiling_delay: retry_delay,
            reset_policy: Impl::RetryState::AfterConsecutiveSuccesses.new(2), random: no_jitter))
        request_times = Queue.new
        with_server do |server|
          server.setup_response("/all") do |_req, res|
            request_times << Time.now
            res.status = 503
          end
          config = Config.new(stream_uri: server.base_uri.to_s, logger: logger)
          config.data_source_update_sink = Impl::DataSource::UpdateSink.new(config.feature_store, status_broadcaster, flag_change_broadcaster)
          processor = subject.new("sdk_key", config)
          threads_before = Thread.list
          processor.start
          sse_thread = (Thread.list - threads_before).detect { |t| t.name == "LD/SSEClient" }
          begin
            yield processor, request_times, sse_thread
          ensure
            processor.stop
          end
        end
      end

      def pop_within(queue, seconds)
        deadline = Time.now + seconds
        while Time.now < deadline
          return queue.pop(true) unless queue.empty?
          sleep(0.01)
        end
        nil
      end

      it 'does not reconnect before the retry delay' do
        with_failing_stream(0.5) do |_processor, request_times|
          first = pop_within(request_times, 5)
          second = pop_within(request_times, 5)
          expect(first).not_to be_nil
          expect(second).not_to be_nil
          expect(second - first).to be >= 0.45
        end
      end

      it 'ends the retry wait at once when stopped, with no further request' do
        with_failing_stream(30) do |processor, request_times, sse_thread|
          expect(pop_within(request_times, 5)).not_to be_nil
          sleep(0.2)
          expect(sse_thread).to be_alive

          processor.stop
          expect(sse_thread.join(1)).not_to be_nil
          expect(pop_within(request_times, 0.5)).to be_nil
        end
      end
    end

    describe 'SSE client options' do
      def captured_sse_options(processor)
        captured = nil
        allow(SSE::Client).to receive(:new) do |_uri, **opts|
          captured = opts
          double("SSE::Client", close: nil)
        end

        processor.start
        processor.stop
        captured
      end

      it 'passes the default connect timeout' do
        opts = captured_sse_options(processor)
        expect(opts[:connect_timeout]).to eq(Config.default_connect_timeout)
      end

      it 'passes a configured connect timeout' do
        config = Config.new(connect_timeout: 0.5)
        opts = captured_sse_options(subject.new("sdk_key", config))
        expect(opts[:connect_timeout]).to eq(0.5)
      end

      it 'passes the configured client options' do
        socket_factory = Object.new
        config = Config.new(socket_factory: socket_factory, initial_reconnect_delay: 3, logger: $null_log)
        opts = captured_sse_options(subject.new("sdk_key", config))
        expect(opts).to eq(
          headers: Impl::Util.default_http_headers("sdk_key", config),
          read_timeout: Impl::DataSource::READ_TIMEOUT_SECONDS,
          connect_timeout: Config.default_connect_timeout,
          logger: $null_log,
          socket_factory: socket_factory,
          # The SDK owns the reconnect delay, so the configured initial_reconnect_delay does not reach the SSE client.
          reconnect_time: 0
        )
      end

      it 'abandons a connect attempt after the connect timeout' do
        socket_factory = HangingSocketFactory.new
        config = Config.new(
          stream_uri: "http://stream.example.com",
          connect_timeout: 0.2,
          socket_factory: socket_factory,
          logger: $null_log
        )
        processor = subject.new("sdk_key", config)

        processor.start
        begin
          # Without the connect timeout, the attempt blocks for the SSE client default of 10 seconds.
          blocked = socket_factory.first_blocked_duration(3)
          expect(blocked).not_to be_nil
          expect(blocked).to be < 1
        ensure
          processor.stop
        end
      end
    end

    describe '#log_connection_result' do
      it "logs successful connection when diagnostic_accumulator is provided" do
        diagnostic_accumulator = double("DiagnosticAccumulator")
        expect(diagnostic_accumulator).to receive(:record_stream_init).with(
          kind_of(Integer),
          false,
          kind_of(Integer)
        )

        processor = subject.new("sdk_key", config, diagnostic_accumulator)
        processor.send(:log_connection_started)
        processor.send(:log_connection_result, true)
      end

      it "logs failed connection when diagnostic_accumulator is provided" do
        diagnostic_accumulator = double("DiagnosticAccumulator")
        expect(diagnostic_accumulator).to receive(:record_stream_init).with(
          kind_of(Integer),
          true,
          kind_of(Integer)
        )

        processor = subject.new("sdk_key", config, diagnostic_accumulator)
        processor.send(:log_connection_started)
        processor.send(:log_connection_result, false)
      end

      it "logs connection metrics with correct timestamp and duration" do
        diagnostic_accumulator = double("DiagnosticAccumulator")

        processor = subject.new("sdk_key", config, diagnostic_accumulator)

        expect(diagnostic_accumulator).to receive(:record_stream_init) do |timestamp, failed, duration|
          expect(timestamp).to be_a(Integer)
          expect(timestamp).to be > 0
          expect(failed).to eq(false)
          expect(duration).to be_a(Integer)
          expect(duration).to be >= 0
        end

        processor.send(:log_connection_started)
        sleep(0.01) # Small delay to ensure measurable duration
        processor.send(:log_connection_result, true)
      end

      it "measures duration on the monotonic clock, unaffected by wall-clock steps" do
        diagnostic_accumulator = double("DiagnosticAccumulator")

        processor = subject.new("sdk_key", config, diagnostic_accumulator)

        expect(diagnostic_accumulator).to receive(:record_stream_init) do |_timestamp, _failed, duration|
          # A backward wall-clock step used to produce a negative duration here.
          expect(duration).to be >= 0
          expect(duration).to be < 1000
        end

        processor.send(:log_connection_started)
        Timecop.freeze(Time.now - 120) do
          processor.send(:log_connection_result, true)
        end
      end

      it "only logs once per connection attempt" do
        diagnostic_accumulator = double("DiagnosticAccumulator")
        expect(diagnostic_accumulator).to receive(:record_stream_init).once

        processor = subject.new("sdk_key", config, diagnostic_accumulator)
        processor.send(:log_connection_started)
        processor.send(:log_connection_result, true)
        # Second call should not trigger another log
        processor.send(:log_connection_result, true)
      end

      it "works gracefully when no diagnostic_accumulator is provided" do
        processor = subject.new("sdk_key", config, nil)

        expect {
          processor.send(:log_connection_started)
          processor.send(:log_connection_result, true)
        }.not_to raise_error
      end
    end
  end
end
