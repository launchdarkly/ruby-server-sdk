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

        it "can stop while the availability poller is running" do
          sink = double
          store = double
          checking = Concurrent::Event.new

          allow(store).to receive(:stop)
          allow(store).to receive(:monitoring_enabled?).and_return(true)
          allow(store).to receive(:all).and_raise(StandardError.new('read error'))
          allow(sink).to receive(:update_status)
          # Hold the poller's thread inside its availability check, so that stop has to wait
          # for a thread that still needs the lock stop holds.
          allow(store).to receive(:available?) do
            checking.set
            sleep 0.25
            true
          end

          wrapper = FeatureStoreClientWrapper.new(store, sink, $null_log)

          begin
            wrapper.all(:features)
            raise "all should have raised exception"
          rescue StandardError
            # Ignored. The failed read starts the availability poller.
          end

          expect(checking.wait(2)).to be true

          stopped = Concurrent::Event.new
          Thread.new do
            wrapper.stop
            stopped.set
          end

          expect(stopped.wait(5)).to be true
        end

        it "does not start the availability poller after stop" do
          sink = double
          store = double
          checks = Concurrent::AtomicFixnum.new(0)

          allow(store).to receive(:stop)
          allow(store).to receive(:monitoring_enabled?).and_return(true)
          allow(store).to receive(:all).and_raise(StandardError.new('read error'))
          allow(sink).to receive(:update_status)
          allow(store).to receive(:available?) { checks.increment; true }

          wrapper = FeatureStoreClientWrapper.new(store, sink, $null_log)
          wrapper.stop

          begin
            wrapper.all(:features)
            raise "all should have raised exception"
          rescue StandardError
            # Ignored. On a running wrapper this would start the poller.
          end

          # The poller is the only caller of available?, so it never ran.
          sleep 1
          expect(checks.value).to eq 0
        end
      end
    end
  end
end
