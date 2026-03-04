require "spec_helper"
require "ldclient-rb/impl/flag_tracker"

module LaunchDarkly
  module Impl
    describe FlagTracker do
      subject { FlagTracker }
      let(:executor) { SynchronousExecutor.new }
      let(:broadcaster) { Broadcaster.new(executor, $null_log) }

      it "can add and remove listeners as expected" do
        listener = ListenerSpy.new

        tracker = subject.new(broadcaster, Proc.new {})
        tracker.add_listener(listener)

        broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(:flag1))
        broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(:flag2))

        tracker.remove_listener(listener)

        broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(:flag3))

        expect(listener.statuses.count).to eq(2)
        expect(listener.statuses[0].key).to eq(:flag1)
        expect(listener.statuses[1].key).to eq(:flag2)
      end

      describe "cross-type key handling" do
        it "String FlagChange + String listener key" do
          responses = [:initial, :second]
          eval_fn = Proc.new { |key, _ctx| responses.shift }
          tracker = subject.new(broadcaster, eval_fn)

          listener = ListenerSpy.new
          tracker.add_flag_value_change_listener("flag1", nil, listener)

          broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new("flag1"))
          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].key).to eq("flag1")
          expect(listener.statuses[0].key).to be_a(String)
        end

        it "String FlagChange + Symbol listener key" do
          responses = [:initial, :second]
          eval_fn = Proc.new { |key, _ctx| responses.shift }
          tracker = subject.new(broadcaster, eval_fn)

          listener = ListenerSpy.new
          tracker.add_flag_value_change_listener(:flag1, nil, listener)

          broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new("flag1"))
          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].key).to eq("flag1")
          expect(listener.statuses[0].key).to be_a(String)
        end

        it "Symbol FlagChange + String listener key" do
          responses = [:initial, :second]
          eval_fn = Proc.new { |key, _ctx| responses.shift }
          tracker = subject.new(broadcaster, eval_fn)

          listener = ListenerSpy.new
          tracker.add_flag_value_change_listener("flag1", nil, listener)

          broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(:flag1))
          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].key).to eq("flag1")
          expect(listener.statuses[0].key).to be_a(String)
        end

        it "eval_fn always receives String key" do
          received_keys = []
          eval_fn = Proc.new { |key, _ctx| received_keys << key; :value }
          tracker = subject.new(broadcaster, eval_fn)

          listener = ListenerSpy.new
          tracker.add_flag_value_change_listener(:flag1, nil, listener)

          # The initial eval in the constructor should have passed a String
          expect(received_keys.length).to eq(1)
          expect(received_keys[0]).to be_a(String)
          expect(received_keys[0]).to eq("flag1")

          # Trigger an update
          broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new("flag1"))

          expect(received_keys.length).to eq(2)
          expect(received_keys[1]).to be_a(String)
          expect(received_keys[1]).to eq("flag1")
        end
      end

      describe "flag change listener" do
        it "listener is notified when value changes" do
          responses = [:initial, :second, :second, :final]
          eval_fn = Proc.new { responses.shift }
          tracker = subject.new(broadcaster, eval_fn)

          listener = ListenerSpy.new
          tracker.add_flag_value_change_listener(:flag1, nil, listener)
          expect(listener.statuses.count).to eq(0)

          broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(:flag1))
          expect(listener.statuses.count).to eq(1)

          # No change was returned here (:second -> :second), so expect no change
          broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(:flag1))
          expect(listener.statuses.count).to eq(1)

          broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(:flag1))
          expect(listener.statuses.count).to eq(2)

          expect(listener.statuses[0].key).to eq("flag1")
          expect(listener.statuses[0].old_value).to eq(:initial)
          expect(listener.statuses[0].new_value).to eq(:second)

          expect(listener.statuses[1].key).to eq("flag1")
          expect(listener.statuses[1].old_value).to eq(:second)
          expect(listener.statuses[1].new_value).to eq(:final)
        end

        it "returns a listener which we can unregister" do
          responses = [:initial, :second, :third]
          eval_fn = Proc.new { responses.shift }
          tracker = subject.new(broadcaster, eval_fn)

          listener = ListenerSpy.new
          created_listener = tracker.add_flag_value_change_listener(:flag1, nil, listener)
          expect(listener.statuses.count).to eq(0)

          broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(:flag1))
          expect(listener.statuses.count).to eq(1)

          tracker.remove_listener(created_listener)
          broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(:flag1))
          expect(listener.statuses.count).to eq(1)

          expect(listener.statuses[0].old_value).to eq(:initial)
          expect(listener.statuses[0].new_value).to eq(:second)
        end
      end
    end

  end
end
