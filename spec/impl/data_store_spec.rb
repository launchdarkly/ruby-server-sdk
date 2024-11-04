require "spec_helper"

module LaunchDarkly
  module Impl
    module DataStore
      describe DataKind do
        describe "eql?" do
          it "constant instances are equal to themselves" do
            expect(LaunchDarkly::FEATURES.eql?(LaunchDarkly::FEATURES)).to be true
            expect(LaunchDarkly::SEGMENTS.eql?(LaunchDarkly::SEGMENTS)).to be true
          end

          it "same constructions are equal" do
            expect(LaunchDarkly::FEATURES.eql?(DataKind.new(namespace: "features", priority: 1))).to be true
            expect(DataKind.new(namespace: "features", priority: 1).eql?(DataKind.new(namespace: "features", priority: 1))).to be true

            expect(LaunchDarkly::SEGMENTS.eql?(DataKind.new(namespace: "segments", priority: 0))).to be true
            expect(DataKind.new(namespace: "segments", priority: 0).eql?(DataKind.new(namespace: "segments", priority: 0))).to be true
          end

          it "distinct namespaces are not equal" do
            expect(DataKind.new(namespace: "features", priority: 1).eql?(DataKind.new(namespace: "segments", priority: 1))).to be false
          end

          it "distinct priorities are not equal" do
            expect(DataKind.new(namespace: "features", priority: 1).eql?(DataKind.new(namespace: "features", priority: 2))).to be false
            expect(DataKind.new(namespace: "segments", priority: 1).eql?(DataKind.new(namespace: "segments", priority: 2))).to be false
          end

          it "handles non-DataKind objects" do
            ["example", true, 1, 1.0, [], {}].each do |obj|
              expect(LaunchDarkly::FEATURES.eql?(obj)).to be false
            end
          end
        end

        describe "hash" do
          it "constant instances are equal to themselves" do
            expect(LaunchDarkly::FEATURES.hash).to be LaunchDarkly::FEATURES.hash
            expect(LaunchDarkly::SEGMENTS.hash).to be LaunchDarkly::SEGMENTS.hash
          end

          it "same constructions are equal" do
            expect(LaunchDarkly::FEATURES.hash).to be DataKind.new(namespace: "features", priority: 1).hash
            expect(DataKind.new(namespace: "features", priority: 1).hash).to be DataKind.new(namespace: "features", priority: 1).hash

            expect(LaunchDarkly::SEGMENTS.hash).to be DataKind.new(namespace: "segments", priority: 0).hash
            expect(DataKind.new(namespace: "segments", priority: 0).hash).to be DataKind.new(namespace: "segments", priority: 0).hash
          end

          it "distinct namespaces are not equal" do
            expect(DataKind.new(namespace: "features", priority: 1).hash).not_to be DataKind.new(namespace: "segments", priority: 1).hash
          end

          it "distinct priorities are not equal" do
            expect(DataKind.new(namespace: "features", priority: 1).hash).not_to be DataKind.new(namespace: "features", priority: 2).hash
            expect(DataKind.new(namespace: "segments", priority: 1).hash).not_to be DataKind.new(namespace: "segments", priority: 2).hash
          end
        end
      end
    end
  end
end
