require "spec_helper"
require 'ostruct'

describe LaunchDarkly::PollingProcessor do
  subject { LaunchDarkly::PollingProcessor }
  let(:requestor) { double() }

  def with_processor(store)
    config = LaunchDarkly::Config.new(feature_store: store)
    processor = subject.new(config, requestor)
    begin
      yield processor
    ensure
      processor.stop
    end
  end

  describe 'successful request' do
    flag = { key: 'flagkey', version: 1 }
    segment = { key: 'segkey', version: 1 }
    all_data = {
      flags: {
        flagkey: flag
      },
      segments: {
        segkey: segment
      }
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
  end

  describe 'connection error' do
    it 'does not cause immediate failure, does not set initialized' do
      allow(requestor).to receive(:request_all_data).and_raise(StandardError.new("test error"))
      store = LaunchDarkly::InMemoryFeatureStore.new
      with_processor(store) do |processor|
        ready = processor.start
        finished = ready.wait(0.2)
        expect(finished).to be false
        expect(processor.initialized?).to be false
        expect(store.initialized?).to be false
      end
    end
  end

  describe 'HTTP errors' do
    def verify_unrecoverable_http_error(status)
      allow(requestor).to receive(:request_all_data).and_raise(LaunchDarkly::UnexpectedResponseError.new(status))
      with_processor(LaunchDarkly::InMemoryFeatureStore.new) do |processor|
        ready = processor.start
        finished = ready.wait(0.2)
        expect(finished).to be true
        expect(processor.initialized?).to be false
      end
    end

    def verify_recoverable_http_error(status)
      allow(requestor).to receive(:request_all_data).and_raise(LaunchDarkly::UnexpectedResponseError.new(status))
      with_processor(LaunchDarkly::InMemoryFeatureStore.new) do |processor|
        ready = processor.start
        finished = ready.wait(0.2)
        expect(finished).to be false
        expect(processor.initialized?).to be false
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
      with_processor(LaunchDarkly::InMemoryFeatureStore.new) do |processor|
        sleep(1)  # somewhat arbitrary, but should ensure that it has started polling
        start_time = Time.now
        processor.stop
        end_time = Time.now
        expect(end_time - start_time).to be <(LaunchDarkly::Config.default_poll_interval - 5)
      end
    end
  end
end
