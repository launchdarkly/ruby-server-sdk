require "ldclient-rb/impl/store_client_wrapper"
require "spec_helper"

module LaunchDarkly
  module Impl
    describe FeatureStoreClientWrapper do
      describe "store listener" do
        it "will not notify sink if wrapped store does not support monitoring" do
          store = double
          sink = double

          allow(store).to receive(:stop)
          allow(store).to receive(:monitoring_enabled?).and_return(false)
          allow(store).to receive(:init).and_raise(StandardError.new('init error'))

          ensure_stop(FeatureStoreClientWrapper.new(store, sink, $null_log)) do |wrapper|
            begin
              wrapper.init({})
              raise "init should have raised exception"
            rescue StandardError
              # Ignored
            end

            expect(sink).not_to receive(:update_status)
          end
        end

        it "will not notify sink if wrapped store cannot come back online" do
          store = double
          sink = double

          allow(store).to receive(:stop)
          allow(store).to receive(:monitoring_enabled?).and_return(true)
          allow(store).to receive(:init).and_raise(StandardError.new('init error'))

          ensure_stop(FeatureStoreClientWrapper.new(store, sink, $null_log)) do |wrapper|
            begin
              wrapper.init({})
              raise "init should have raised exception"
            rescue StandardError
              # Ignored
            end

            expect(sink).not_to receive(:update_status)
          end
        end

        it "sink will be notified when store is back online" do
          event = Concurrent::Event.new
          statuses = []
          listener = CallbackListener.new(->(status) {
            statuses << status
            event.set if status.available?
          })

          broadcaster = Broadcaster.new(SynchronousExecutor.new, $null_log)
          broadcaster.add_listener(listener)
          sink = DataStore::UpdateSink.new(broadcaster)
          store = double

          allow(store).to receive(:stop)
          allow(store).to receive(:monitoring_enabled?).and_return(true)
          allow(store).to receive(:available?).and_return(false, true)
          allow(store).to receive(:init).and_raise(StandardError.new('init error'))

          ensure_stop(FeatureStoreClientWrapper.new(store, sink, $null_log)) do |wrapper|
            begin
              wrapper.init({})
              raise "init should have raised exception"
            rescue StandardError
              # Ignored
            end

            event.wait(2)

            expect(statuses.count).to eq(2)
            expect(statuses[0].available).to be false
            expect(statuses[1].available).to be true
          end
        end
      end
    end
  end
end
