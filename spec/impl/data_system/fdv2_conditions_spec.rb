# frozen_string_literal: true

require "ldclient-rb"

require "spec_helper"

module LaunchDarkly
  module Impl
    module DataSystem
      describe FDv2 do
        # The condition predicates are pure functions of (status, seconds_in_state),
        # so no construction is needed.
        subject { described_class.allocate }

        def status(state)
          LaunchDarkly::Interfaces::DataSource::Status.new(state, Time.now, nil)
        end

        states = LaunchDarkly::Interfaces::DataSource::Status

        describe "fallback_condition" do
          [
            [states::INTERRUPTED, 59, false],
            [states::INTERRUPTED, 60, false], # strictly greater than
            [states::INTERRUPTED, 61, true],
            [states::INITIALIZING, 9, false],
            [states::INITIALIZING, 10, false], # strictly greater than
            [states::INITIALIZING, 11, true],
            [states::VALID, 10_000, false],
            [states::OFF, 10_000, false],
          ].each do |state, seconds, expected|
            it "is #{expected} for #{state} at #{seconds}s" do
              expect(subject.send(:fallback_condition, status(state), seconds)).to be expected
            end
          end
        end

        describe "recovery_condition" do
          [
            [states::VALID, 299, false],
            [states::VALID, 300, false], # strictly greater than
            [states::VALID, 301, true],
            [states::INTERRUPTED, 10_000, false],
            [states::INITIALIZING, 10_000, false],
            [states::OFF, 10_000, false],
          ].each do |state, seconds, expected|
            it "is #{expected} for #{state} at #{seconds}s" do
              expect(subject.send(:recovery_condition, status(state), seconds)).to be expected
            end
          end
        end
      end
    end
  end
end
