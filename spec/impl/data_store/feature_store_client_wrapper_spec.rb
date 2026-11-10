# frozen_string_literal: true

require "spec_helper"
require "ldclient-rb/impl/data_store/feature_store_client_wrapper"
require "ldclient-rb/impl/data_store/status_provider"
require "ldclient-rb/impl/broadcaster"

module LaunchDarkly
  module Impl
    module DataStore
      describe FeatureStoreClientWrapperV2 do
        let(:logger) { double.as_null_object }
        let(:status_sink) { double(update_status: nil) }

        describe "required store methods" do
          [true, false].each do |enabled|
            it "reports monitoring_enabled? #{enabled} from the store" do
              inner = double("store", monitoring_enabled?: enabled)
              expect(described_class.new(inner, status_sink, logger).monitoring_enabled?).to be enabled
            end
          end

          [true, false].each do |available|
            it "gets available? #{available} from the store" do
              inner = double("store", monitoring_enabled?: true, available?: available)
              expect(described_class.new(inner, status_sink, logger).available?).to be available
            end
          end

          it "stops the store" do
            inner = double("store", monitoring_enabled?: false)
            expect(inner).to receive(:stop).once
            described_class.new(inner, status_sink, logger).stop
          end
        end

        describe "availability monitoring" do
          # Calls the block and ignores the error that it raises.
          def ignore_error
            yield
            raise "the block did not raise an error"
          rescue StandardError => e
            raise if e.message == "the block did not raise an error"
          end

          it "does not notify the sink when the store does not support monitoring" do
            inner = double("store", stop: nil, monitoring_enabled?: false)
            allow(inner).to receive(:init).and_raise(StandardError.new("init error"))
            sink = double("sink")
            expect(sink).not_to receive(:update_status)
            expect(LaunchDarkly::Impl::RepeatingTask).not_to receive(:new)

            ensure_stop(described_class.new(inner, sink, logger)) do |wrapper|
              ignore_error { wrapper.init({}) }
            end
          end

          it "notifies the status provider when the store becomes unavailable and when it recovers" do
            listener = ListenerSpy.new
            broadcaster = LaunchDarkly::Impl::Broadcaster.new(SynchronousExecutor.new, $null_log)
            broadcaster.add_listener(listener)
            inner = double("store", stop: nil, monitoring_enabled?: true)
            allow(inner).to receive(:available?).and_return(false, true)
            allow(inner).to receive(:init).and_raise(StandardError.new("init error"))
            sink = LaunchDarkly::Impl::DataStore::StatusProviderV2.new(inner, broadcaster)

            ensure_stop(described_class.new(inner, sink, logger)) do |wrapper|
              ignore_error { wrapper.init({}) }

              statuses = listener.wait_for_count(2)
              expect(statuses.map(&:available)).to eq([false, true])
              expect(statuses.map(&:stale)).to eq([true, true])
              expect(sink.status.available).to be true
            end
          end

          it "can stop while the availability poller is running" do
            checking = Concurrent::Event.new
            release = Concurrent::Event.new
            inner = double("store", stop: nil, monitoring_enabled?: true)
            allow(inner).to receive(:all).and_raise(StandardError.new("read error"))
            # Hold the poller thread inside its availability check while stop runs.
            allow(inner).to receive(:available?) do
              checking.set
              release.wait(5)
              true
            end

            wrapper = described_class.new(inner, status_sink, logger)
            ignore_error { wrapper.all(:features) }
            expect(checking.wait(2)).to be true

            stopped = Concurrent::Event.new
            stopper = Thread.new do
              wrapper.stop
              stopped.set
            end
            # Stop waits for the poller thread to finish its check.
            expect(stopped.wait(0.1)).to be false
            release.set

            expect(stopped.wait(5)).to be true
            stopper.join(1)
            expect(inner).to have_received(:stop).once
          end

          it "does not start the availability poller after stop" do
            inner = double("store", stop: nil, monitoring_enabled?: true, available?: true)
            allow(inner).to receive(:all).and_raise(StandardError.new("read error"))
            sink = double("sink")
            expect(sink).not_to receive(:update_status)
            expect(LaunchDarkly::Impl::RepeatingTask).not_to receive(:new)

            wrapper = described_class.new(inner, sink, logger)
            wrapper.stop

            ignore_error { wrapper.all(:features) }
          end
        end

        describe "#disable_cache" do
          it "forwards to the underlying store when supported" do
            inner = double("store", disable_cache: nil, init: nil, get: nil, all: nil, delete: nil, upsert: nil, initialized?: false,
                                    stop: nil, monitoring_enabled?: false, available?: true)
            expect(inner).to receive(:disable_cache).once

            wrapper = described_class.new(inner, status_sink, logger)
            wrapper.disable_cache
          end

          it "is a no-op when the underlying store does not respond to disable_cache" do
            inner = Class.new do
              def init(_); end
              def get(_, _); end
              def all(_); end
              def delete(_, _, _); end
              def upsert(_, _); end
              def initialized?; false; end
              def monitoring_enabled?; false; end
              def available?; true; end
              def stop; end
            end.new

            wrapper = described_class.new(inner, status_sink, logger)
            expect { wrapper.disable_cache }.not_to raise_error
          end
        end
      end
    end
  end
end
