require "spec_helper"
require "ldclient-rb/impl/data_source/null_processor"

module LaunchDarkly
  module Impl
    module DataSource
      describe NullUpdateProcessor do
        subject { NullUpdateProcessor.new }

        describe "#initialize" do
          it "creates a ready event" do
            expect(subject.instance_variable_get(:@ready)).to be_a(Concurrent::Event)
          end
        end

        describe "#start" do
          it "returns a ready event that is already set" do
            ready_event = subject.start
            expect(ready_event).to be_a(Concurrent::Event)
            expect(ready_event.set?).to be true
          end

          it "returns the same event on multiple calls" do
            first_event = subject.start
            second_event = subject.start

            expect(second_event).to be(first_event)
          end
        end

        describe "#stop" do
          it "does nothing and does not raise an error" do
            expect { subject.stop }.not_to raise_error
          end
        end

        describe "#initialized?" do
          it "always returns true" do
            expect(subject.initialized?).to be true
          end

          it "returns true even before start is called" do
            processor = NullUpdateProcessor.new
            expect(processor.initialized?).to be true
          end
        end

        describe "DataSource interface" do
          it "includes the DataSource module" do
            expect(subject.class.ancestors).to include(LaunchDarkly::Interfaces::DataSource)
          end
        end
      end
    end
  end
end

