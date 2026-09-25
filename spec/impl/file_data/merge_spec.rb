# frozen_string_literal: true

require "spec_helper"
require "capturing_logger"
require "ldclient-rb/impl/file_data"

module LaunchDarkly
  module Impl
    module FileData
      describe "merge" do
        def document(flags: {}, flag_values: {}, segments: {})
          Document.new(flags: flags, flag_values: flag_values, segments: segments)
        end

        def full_flag(key, version: nil)
          data = { key: key, on: true, variations: ["a", "b"], fallthrough: { variation: 1 } }
          data[:version] = version unless version.nil?
          data
        end

        it "combines flags, flag values, and segments from documents in order" do
          doc1 = document(flags: { flag1: full_flag("flag1") }, segments: { seg1: { key: "seg1", included: ["u"] } })
          doc2 = document(flag_values: { flag2: "value2" })

          result = FileData.merge([doc1, doc2])

          expect(result.flags.keys).to eq([:flag1, :flag2])
          expect(result.flags[:flag1]).to be_a(Model::FeatureFlag)
          expect(result.flags[:flag2]).to be_a(Model::FeatureFlag)
          expect(result.segments.keys).to eq([:seg1])
          expect(result.segments[:seg1]).to be_a(Model::Segment)
          expect(result.documents).to eq([DocumentSummary.new(1, 1), DocumentSummary.new(1, 0)])
          expect(result.empty?).to be false
        end

        it "expands a flag value into a flag that serves the value for every context" do
          result = FileData.merge([document(flag_values: { flag2: "value2" })])

          flag = result.flags[:flag2]
          expect(flag.key).to eq("flag2")
          expect(flag.on).to be true
          expect(flag.version).to eq(1)
          expect(flag.variations).to eq(["value2"])
          expect(flag.fallthrough.variation).to eq(0)
        end

        it "reports an empty result for no documents" do
          expect(FileData.merge([]).empty?).to be true
        end

        it "fails when the same flag key appears in two documents" do
          docs = [document(flags: { flag1: full_flag("flag1") }), document(flags: { flag1: full_flag("flag1") })]

          expect { FileData.merge(docs) }.to raise_error(MergeError, /flag key "flag1" was used more than once/)
        end

        it "fails when the same segment key appears in two documents" do
          docs = [document(segments: { seg1: { key: "seg1" } }), document(segments: { seg1: { key: "seg1" } })]

          expect { FileData.merge(docs) }.to raise_error(MergeError, /segment key "seg1" was used more than once/)
        end

        it "fails when a key appears in both flags and flagValues of one document" do
          docs = [document(flags: { flag1: full_flag("flag1") }, flag_values: { flag1: "x" })]

          expect { FileData.merge(docs) }.to raise_error(MergeError, /flag key "flag1"/)
        end

        it "keeps the first document's entry and drops later duplicates with ignore handling" do
          doc1 = document(flag_values: { flag1: "first" })
          doc2 = document(flag_values: { flag1: "second", flag2: "other" })

          result = FileData.merge([doc1, doc2], duplicate_keys_handling: DuplicateKeysHandling::IGNORE)

          expect(result.flags[:flag1].variations).to eq(["first"])
          expect(result.flags[:flag2].variations).to eq(["other"])
          expect(result.documents).to eq([DocumentSummary.new(1, 0), DocumentSummary.new(1, 0)])
        end

        it "defaults a missing version to 1 and keeps a given version" do
          doc = document(
            flags: { flag1: full_flag("flag1"), flag2: full_flag("flag2", version: 5) },
            segments: { seg1: { key: "seg1" }, seg2: { key: "seg2", version: 9 } }
          )

          result = FileData.merge([doc])

          expect(result.flags[:flag1].version).to eq(1)
          expect(result.flags[:flag2].version).to eq(5)
          expect(result.segments[:seg1].version).to eq(1)
          expect(result.segments[:seg2].version).to eq(9)
        end

        it "stamps the given version on every entry" do
          doc = document(flags: { flag1: full_flag("flag1", version: 5) }, flag_values: { flag2: "x" },
            segments: { seg1: { key: "seg1", version: 9 } })

          result = FileData.merge([doc], version: 42)

          expect(result.flags[:flag1].version).to eq(42)
          expect(result.flags[:flag2].version).to eq(42)
          expect(result.segments[:seg1].version).to eq(42)
        end

        it "fills a missing key member from the key the entry appears under" do
          doc = document(flags: { flag1: { on: false, variations: [1] } }, segments: { seg1: {} })

          result = FileData.merge([doc])

          expect(result.flags[:flag1].key).to eq("flag1")
          expect(result.segments[:seg1].key).to eq("seg1")
        end

        it "does not modify the document's own hashes" do
          data = { on: false, variations: [1] }
          FileData.merge([document(flags: { flag1: data })])

          expect(data).to eq({ on: false, variations: [1] })
        end

        it "fails when an entry is not an object" do
          expect { FileData.merge([document(flags: { flag1: 5 })]) }.to raise_error(MergeError, /flag "flag1" is not an object/)
          expect { FileData.merge([document(segments: { seg1: [] })]) }.to raise_error(MergeError, /segment "seg1" is not an object/)
        end

        it "passes the logger to model validation" do
          logger = CapturingLogger.new
          bad = { key: "flag1", on: true, variations: ["a"], fallthrough: { variation: 5 } }

          FileData.merge([document(flags: { flag1: bad })], logger: logger)

          expect(logger.output).to include("Data inconsistency in feature flag \"flag1\"")
        end
      end
    end
  end
end
