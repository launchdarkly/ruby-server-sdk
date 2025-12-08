require "ldclient-rb/impl/data_source/stream"
require "ld-eventsource"
require "model_builders"
require "spec_helper"

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
      it "status listener will trigger error when JSON is invalid" do
        listener = ListenerSpy.new
        status_broadcaster.add_listener(listener)

        begin
          processor.send(:process_message, invalid_message)
        rescue
          # Ignored
        end

        expect(listener.statuses.count).to eq(2)
        expect(listener.statuses[1].state).to eq(Interfaces::DataSource::Status::INTERRUPTED)
        expect(listener.statuses[1].last_error.kind).to eq(Interfaces::DataSource::ErrorInfo::INVALID_DATA)
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
