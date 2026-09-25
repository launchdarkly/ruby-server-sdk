require "ldclient-rb/impl/data_source/polling"
require "ldclient-rb/impl/model/feature_flag"
require "ldclient-rb/impl/model/segment"
require 'ostruct'
require "spec_helper"

module LaunchDarkly
  describe Impl::DataSource::PollingProcessor do
    subject { Impl::DataSource::PollingProcessor }
    let(:executor) { SynchronousExecutor.new }
    let(:status_broadcaster) { Impl::Broadcaster.new(executor, $null_log) }
    let(:flag_change_broadcaster) { Impl::Broadcaster.new(executor, $null_log) }
    let(:requestor) { double }

    def with_processor(store, initialize_to_valid = false)
      config = Config.new(feature_store: store, logger: $null_log)
      config.data_source_update_sink = Impl::DataSource::UpdateSink.new(store, status_broadcaster, flag_change_broadcaster)

      if initialize_to_valid
        # If the update sink receives an interrupted signal when the state is
        # still initializing, it will continue staying in the initializing phase.
        # Therefore, we set the state to valid before this test so we can
        # determine if the interrupted signal is actually generated.
        config.data_source_update_sink.update_status(Interfaces::DataSource::Status::VALID, nil)
      end

      processor = subject.new(config, requestor)
      begin
        yield processor
      ensure
        processor.stop
      end
    end

    describe 'successful request' do
      flag = Impl::Model::FeatureFlag.new({ key: 'flagkey', version: 1 })
      segment = Impl::Model::Segment.new({ key: 'segkey', version: 1 })
      all_data = {
        Impl::DataStore::FEATURES => {
          flagkey: flag,
        },
        Impl::DataStore::SEGMENTS => {
          segkey: segment,
        },
      }

      it 'puts feature data in store' do
        allow(requestor).to receive(:request_all_data).and_return(all_data)
        store = InMemoryFeatureStore.new
        with_processor(store) do |processor|
          ready = processor.start
          ready.wait
          expect(store.get(Impl::DataStore::FEATURES, "flagkey")).to eq(flag)
          expect(store.get(Impl::DataStore::SEGMENTS, "segkey")).to eq(segment)
        end
      end

      it 'sets initialized to true' do
        allow(requestor).to receive(:request_all_data).and_return(all_data)
        store = InMemoryFeatureStore.new
        with_processor(store) do |processor|
          ready = processor.start
          ready.wait
          expect(processor.initialized?).to be true
          expect(store.initialized?).to be true
        end
      end

      it 'status is set to valid when data is received' do
        allow(requestor).to receive(:request_all_data).and_return(all_data)
        listener = ListenerSpy.new
        status_broadcaster.add_listener(listener)

        store = InMemoryFeatureStore.new
        with_processor(store) do |processor|
          ready = processor.start
          ready.wait
          expect(store.get(Impl::DataStore::FEATURES, "flagkey")).to eq(flag)
          expect(store.get(Impl::DataStore::SEGMENTS, "segkey")).to eq(segment)

          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].state).to eq(Interfaces::DataSource::Status::VALID)
        end
      end
    end

    describe 'environment ID' do
      flag = Impl::Model::FeatureFlag.new({ key: 'flagkey', version: 1 })
      all_data = {
        Impl::DataStore::FEATURES => { flagkey: flag },
        Impl::DataStore::SEGMENTS => {},
      }

      it 'is recorded from the response headers' do
        allow(requestor).to receive(:request_all_data_with_headers).and_return([all_data, { "X-LD-EnvID" => "env-abc" }])
        store = InMemoryFeatureStore.new
        with_processor(store) do |processor|
          config = processor.instance_variable_get(:@config)
          processor.start.wait
          expect(config.data_source_update_sink.environment_id).to eq("env-abc")
        end
      end

      it 'is not recorded when the header is absent' do
        allow(requestor).to receive(:request_all_data_with_headers).and_return([all_data, {}])
        store = InMemoryFeatureStore.new
        with_processor(store) do |processor|
          config = processor.instance_variable_get(:@config)
          processor.start.wait
          expect(config.data_source_update_sink.environment_id).to be_nil
        end
      end

      it 'is not recorded for an error response' do
        allow(requestor).to receive(:request_all_data_with_headers).and_raise(Impl::DataSource::UnexpectedResponseError.new(503))
        with_processor(InMemoryFeatureStore.new, true) do |processor|
          config = processor.instance_variable_get(:@config)
          processor.start.wait(1)
          expect(config.data_source_update_sink.environment_id).to be_nil
        end
      end
    end

    describe 'connection error' do
      it 'does not cause immediate failure, does not set initialized' do
        allow(requestor).to receive(:request_all_data).and_raise(StandardError.new("test error"))
        store = InMemoryFeatureStore.new
        with_processor(store) do |processor|
          ready = processor.start
          finished = ready.wait(1)
          expect(finished).to be false
          expect(processor.initialized?).to be false
          expect(store.initialized?).to be false
        end
      end
    end

    describe 'HTTP errors' do
      # Delays short enough that the task polls again at once.
      let(:fast_retry_state) {
        Impl::RetryState.new(normal_initial_delay: 0.001, normal_ceiling_delay: 0.001, extended_initial_delay: 0.002,
          extended_ceiling_delay: 0.002, reset_policy: Impl::RetryState::AfterConsecutiveSuccesses.new(2),
          operating_cadence: 0.001)
      }

      def verify_unexpected_http_error_keeps_retrying(status)
        allow(Impl::RetryState).to receive(:for_polling).and_return(fast_retry_state)
        attempts = Concurrent::CountDownLatch.new(3)
        allow(requestor).to receive(:request_all_data) do
          attempts.count_down
          raise Impl::DataSource::UnexpectedResponseError.new(status)
        end
        listener = ListenerSpy.new
        status_broadcaster.add_listener(listener)

        with_processor(InMemoryFeatureStore.new, true) do |processor|
          ready = processor.start
          expect(attempts.wait(1)).to be true
          expect(ready.set?).to be false
          expect(processor.initialized?).to be false

          # The first status is the VALID that with_processor sets.
          states = listener.statuses.map(&:state)
          expect(states[1..2]).to eq([Interfaces::DataSource::Status::INTERRUPTED] * 2)
          expect(states).not_to include(Interfaces::DataSource::Status::OFF)
          expect(listener.statuses[1].last_error.status_code).to eq(status)
        end
      end

      def verify_recoverable_http_error(status)
        allow(requestor).to receive(:request_all_data).and_raise(Impl::DataSource::UnexpectedResponseError.new(status))
        listener = ListenerSpy.new
        status_broadcaster.add_listener(listener)

        with_processor(InMemoryFeatureStore.new, true) do |processor|
          ready = processor.start
          finished = ready.wait(1)
          expect(finished).to be false
          expect(processor.initialized?).to be false

          expect(listener.statuses.count).to eq(2)

          s = listener.statuses[1]
          expect(s.state).to eq(Interfaces::DataSource::Status::INTERRUPTED)
          expect(s.last_error.status_code).to eq(status)
        end
      end

      it 'keeps retrying after error 401' do
        verify_unexpected_http_error_keeps_retrying(401)
      end

      it 'keeps retrying after error 403' do
        verify_unexpected_http_error_keeps_retrying(403)
      end

      it 'keeps retrying after error 404' do
        verify_unexpected_http_error_keeps_retrying(404)
      end

      it 'does not stop immediately for error 408' do
        verify_recoverable_http_error(408)
      end

      it 'does not stop immediately for error 429' do
        verify_recoverable_http_error(429)
      end

      it 'does not stop immediately for error 503' do
        verify_recoverable_http_error(503)
      end
    end

    describe 'retry delay' do
      let(:logger) { double("logger").as_null_object }
      let(:all_data) { { Impl::DataStore::FEATURES => {}, Impl::DataStore::SEGMENTS => {} } }

      def make_processor
        config = Config.new(feature_store: InMemoryFeatureStore.new, logger: logger)
        config.data_source_update_sink = Impl::DataSource::UpdateSink.new(config.feature_store, status_broadcaster, flag_change_broadcaster)
        subject.new(config, requestor)
      end

      def next_delay(processor)
        processor.instance_variable_get(:@retry_state).next_delay
      end

      it 'waits in the extended regime after an unexpected error, then the poll interval after a success' do
        responses = [:unauthorized, :ok]
        allow(requestor).to receive(:request_all_data) do
          raise Impl::DataSource::UnexpectedResponseError.new(401) if responses.shift == :unauthorized
          all_data
        end
        processor = make_processor

        processor.poll
        expect(next_delay(processor)).to be_between(150, 300)
        processor.poll
        expect(next_delay(processor)).to eq(Config.default_poll_interval)
      end

      it 'waits the poll interval after a recoverable error' do
        allow(requestor).to receive(:request_all_data).and_raise(Impl::DataSource::UnexpectedResponseError.new(503))
        processor = make_processor

        processor.poll
        expect(next_delay(processor)).to eq(Config.default_poll_interval)
      end

      it 'waits the poll interval after a network error' do
        allow(requestor).to receive(:request_all_data).and_raise(StandardError.new("test error"))
        processor = make_processor

        processor.poll
        expect(next_delay(processor)).to eq(Config.default_poll_interval)
      end

      it 'logs the real delay for an HTTP error' do
        allow(Impl::RetryState).to receive(:for_polling).and_return(
          Impl::RetryState.for_polling(30, logger, random: double("random", rand: 0.0)))
        allow(requestor).to receive(:request_all_data).and_raise(Impl::DataSource::UnexpectedResponseError.new(401))
        expect(logger).to receive(:error) do |&block|
          expect(block.call).to eq("[LDClient] HTTP error 401 (invalid SDK key) for polling request - will retry in 300.0s")
        end

        make_processor.poll
      end
    end

    describe 'stop' do
      it 'stops promptly rather than continuing to wait for poll interval' do
        listener = ListenerSpy.new
        status_broadcaster.add_listener(listener)

        with_processor(InMemoryFeatureStore.new) do |processor|
          sleep(1)  # somewhat arbitrary, but should ensure that it has started polling
          start_time = Time.now
          processor.stop
          end_time = Time.now
          expect(end_time - start_time).to be <(Config.default_poll_interval - 5)

          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].state).to eq(Interfaces::DataSource::Status::OFF)
        end
      end

      it 'closes requestor HTTP connections on stop' do
        requestor_with_stop = double("RequestorWithStop")
        allow(requestor_with_stop).to receive(:request_all_data).and_return({
          Impl::DataStore::FEATURES => {},
          Impl::DataStore::SEGMENTS => {},
        })
        allow(requestor_with_stop).to receive(:stop)

        config = Config.new(feature_store: InMemoryFeatureStore.new, logger: $null_log)
        config.data_source_update_sink = Impl::DataSource::UpdateSink.new(
          config.feature_store, status_broadcaster, flag_change_broadcaster
        )

        processor = subject.new(config, requestor_with_stop)
        processor.start
        sleep(0.1) # Give it time to start

        expect(requestor_with_stop).to receive(:stop)
        processor.stop
      end
    end
  end
end
