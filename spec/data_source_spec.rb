require "spec_helper"

module LaunchDarkly
  module Impl
    describe DataSource::UpdateSink do
      subject { DataSource::UpdateSink }
      let(:store) { double }
      let(:executor) { SynchronousExecutor.new }
      let(:broadcaster) { LaunchDarkly::Impl::Broadcaster.new(executor, $null_log) }
      let(:sink) { subject.new(store, broadcaster) }

      it "defaults to initializing" do
        expect(sink.current_status.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING)
        expect(sink.current_status.last_error).to be_nil
      end

      it "setting status to interrupted while initializing maintains initializing state" do
        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, nil)
        expect(sink.current_status.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING)
        expect(sink.current_status.last_error).to be_nil
      end

      it "listener is triggered only for state changes" do
        listener = ListenerSpy.new
        broadcaster.add_listener(listener)

        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
        expect(listener.statuses.count).to eq(1)

        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, nil)
        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, nil)
        expect(listener.statuses.count).to eq(2)
      end

      it "all listeners are called for a single change" do
        listener1 = ListenerSpy.new
        broadcaster.add_listener(listener1)

        listener2 = ListenerSpy.new
        broadcaster.add_listener(listener2)

        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
        expect(listener1.statuses.count).to eq(1)
        expect(listener2.statuses.count).to eq(1)
      end

      describe "listeners are triggered for store errors" do
        def confirm_store_error(error_type)
          # Make it valid first so the error changes from initializing
          sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)

          listener = ListenerSpy.new
          broadcaster.add_listener(listener)

          allow(store).to receive(:init).and_raise(StandardError.new("init error"))
          allow(store).to receive(:upsert).and_raise(StandardError.new("upsert error"))
          allow(store).to receive(:delete).and_raise(StandardError.new("delete error"))

          begin
            yield
          rescue
            # ignored
          end

          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
          expect(listener.statuses[0].last_error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::STORE_ERROR)
          expect(listener.statuses[0].last_error.message).to eq("#{error_type} error")
        end

        it "when calling init" do
          confirm_store_error("init") { sink.init({}) }
        end

        it "when calling upsert" do
          confirm_store_error("upsert") { sink.upsert("flag", nil) }
        end

        it "when calling delete" do
          confirm_store_error("delete") { sink.delete("flag", "flag-key", 1) }
        end
      end
    end
  end
end
