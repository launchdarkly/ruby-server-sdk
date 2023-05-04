require "ldclient-rb/impl/model/feature_flag"
require "ldclient-rb/impl/model/segment"
require 'ostruct'
require "spec_helper"

describe LaunchDarkly::PollingProcessor do
  subject { LaunchDarkly::PollingProcessor }
  let(:executor) { SynchronousExecutor.new }
  let(:status_broadcaster) { LaunchDarkly::Impl::Broadcaster.new(executor, $null_log) }
  let(:flag_change_broadcaster) { LaunchDarkly::Impl::Broadcaster.new(executor, $null_log) }
  let(:requestor) { double() }

  def with_processor(store, initialize_to_valid = false)
    config = LaunchDarkly::Config.new(feature_store: store, logger: $null_log)
    config.data_source_update_sink = LaunchDarkly::Impl::DataSource::UpdateSink.new(store, status_broadcaster, flag_change_broadcaster)

    if initialize_to_valid
      # If the update sink receives an interrupted signal when the state is
      # still initializing, it will continue staying in the initializing phase.
      # Therefore, we set the state to valid before this test so we can
      # determine if the interrupted signal is actually generated.
      config.data_source_update_sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
    end

    processor = subject.new(config, requestor)
    begin
      yield processor
    ensure
      processor.stop
    end
  end

  describe 'successful request' do
    flag = LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flagkey', version: 1 })
    segment = LaunchDarkly::Impl::Model::Segment.new({ key: 'segkey', version: 1 })
    all_data = {
      LaunchDarkly::FEATURES => {
        flagkey: flag,
      },
      LaunchDarkly::SEGMENTS => {
        segkey: segment,
      },
    }

    it 'puts feature data in store' do
      allow(requestor).to receive(:request_all_data).and_return(all_data)
      store = LaunchDarkly::InMemoryFeatureStore.new
      with_processor(store) do |processor|
        ready = processor.start
        ready.wait
        expect(store.get(LaunchDarkly::FEATURES, "flagkey")).to eq(flag)
        expect(store.get(LaunchDarkly::SEGMENTS, "segkey")).to eq(segment)
      end
    end

    it 'sets initialized to true' do
      allow(requestor).to receive(:request_all_data).and_return(all_data)
      store = LaunchDarkly::InMemoryFeatureStore.new
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

      store = LaunchDarkly::InMemoryFeatureStore.new
      with_processor(store) do |processor|
        ready = processor.start
        ready.wait
        expect(store.get(LaunchDarkly::FEATURES, "flagkey")).to eq(flag)
        expect(store.get(LaunchDarkly::SEGMENTS, "segkey")).to eq(segment)

        expect(listener.statuses.count).to eq(1)
        expect(listener.statuses[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
      end
    end
  end

  describe 'connection error' do
    it 'does not cause immediate failure, does not set initialized' do
      allow(requestor).to receive(:request_all_data).and_raise(StandardError.new("test error"))
      store = LaunchDarkly::InMemoryFeatureStore.new
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
    def verify_unrecoverable_http_error(status)
      allow(requestor).to receive(:request_all_data).and_raise(LaunchDarkly::UnexpectedResponseError.new(status))
      listener = ListenerSpy.new
      status_broadcaster.add_listener(listener)

      with_processor(LaunchDarkly::InMemoryFeatureStore.new) do |processor|
        ready = processor.start
        finished = ready.wait(1)
        expect(finished).to be true
        expect(processor.initialized?).to be false

        expect(listener.statuses.count).to eq(1)

        s = listener.statuses[0]
        expect(s.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::OFF)
        expect(s.last_error.status_code).to eq(status)
      end
    end

    def verify_recoverable_http_error(status)
      allow(requestor).to receive(:request_all_data).and_raise(LaunchDarkly::UnexpectedResponseError.new(status))
      listener = ListenerSpy.new
      status_broadcaster.add_listener(listener)

      with_processor(LaunchDarkly::InMemoryFeatureStore.new, true) do |processor|
        ready = processor.start
        finished = ready.wait(1)
        expect(finished).to be false
        expect(processor.initialized?).to be false

        expect(listener.statuses.count).to eq(2)

        s = listener.statuses[1]
        expect(s.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
        expect(s.last_error.status_code).to eq(status)
      end
    end

    it 'stops immediately for error 401' do
      verify_unrecoverable_http_error(401)
    end

    it 'stops immediately for error 403' do
      verify_unrecoverable_http_error(403)
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

  describe 'stop' do
    it 'stops promptly rather than continuing to wait for poll interval' do
      listener = ListenerSpy.new
      status_broadcaster.add_listener(listener)

      with_processor(LaunchDarkly::InMemoryFeatureStore.new) do |processor|
        sleep(1)  # somewhat arbitrary, but should ensure that it has started polling
        start_time = Time.now
        processor.stop
        end_time = Time.now
        expect(end_time - start_time).to be <(LaunchDarkly::Config.default_poll_interval - 5)

        expect(listener.statuses.count).to eq(1)
        expect(listener.statuses[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::OFF)
      end
    end
  end
end
