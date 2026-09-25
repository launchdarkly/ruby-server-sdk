# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "ldclient-rb/impl/file_data"

module LaunchDarkly
  module Impl
    module FileData
      describe Document do
        describe "parse" do
          it "parses a JSON document with every section and symbolizes nested keys" do
            document = Document.parse(<<~JSON)
              {
                "flags": { "flag1": { "key": "flag1", "on": true, "rules": [ { "clauses": [ { "op": "in" } ] } ] } },
                "flagValues": { "flag2": "value2" },
                "segments": { "seg1": { "key": "seg1", "included": ["user1"] } }
              }
            JSON

            expect(document.flags.keys).to eq([:flag1])
            expect(document.flags[:flag1][:rules][0][:clauses][0][:op]).to eq("in")
            expect(document.flag_values).to eq({ flag2: "value2" })
            expect(document.segments[:seg1][:included]).to eq(["user1"])
          end

          it "parses a YAML document" do
            document = Document.parse(<<~YAML)
              ---
              flags:
                flag1:
                  key: flag1
                  "on": true
              flagValues:
                flag2: value2
              segments:
                seg1:
                  key: seg1
            YAML

            expect(document.flags[:flag1][:on]).to be true
            expect(document.flag_values).to eq({ flag2: "value2" })
            expect(document.segments.keys).to eq([:seg1])
          end

          it "treats an empty document as a document with no entries" do
            document = Document.parse("")

            expect(document.flags).to eq({})
            expect(document.flag_values).to eq({})
            expect(document.segments).to eq({})
          end

          it "treats a document with no known sections as a document with no entries" do
            document = Document.parse("{}")

            expect(document.flags).to eq({})
            expect(document.flag_values).to eq({})
            expect(document.segments).to eq({})
          end

          it "rejects a document that is not an object" do
            expect { Document.parse("\"hello\"") }.to raise_error(ArgumentError, /must be an object/)
            expect { Document.parse("[1, 2]") }.to raise_error(ArgumentError, /must be an object/)
          end

          it "rejects a section that is not an object" do
            expect { Document.parse('{"flags": []}') }.to raise_error(ArgumentError, /"flags" must be an object/)
            expect { Document.parse('{"flagValues": 3}') }.to raise_error(ArgumentError, /"flagValues" must be an object/)
            expect { Document.parse('{"segments": "x"}') }.to raise_error(ArgumentError, /"segments" must be an object/)
          end

          it "symbolizes keys that YAML parsed as numbers" do
            document = Document.parse("flagValues:\n  123: true\n")

            expect(document.flag_values).to eq({ "123": true })
          end

          it "raises a syntax error for content that cannot be parsed" do
            expect { Document.parse('{"flagValues"') }.to raise_error(Psych::SyntaxError)
          end
        end

        describe "read" do
          around do |example|
            Dir.mktmpdir do |dir|
              @dir = dir
              example.run
            end
          end

          it "reads and parses a file" do
            path = File.join(@dir, "flags.json")
            File.write(path, '{"flagValues": {"flag1": 1}}')

            document = Document.read(path)

            expect(document.flag_values).to eq({ flag1: 1 })
          end

          it "reports a missing file as a read error that is marked missing" do
            path = File.join(@dir, "no-such-file.json")

            expect { Document.read(path) }.to raise_error(ReadError) do |error|
              expect(error.missing).to be true
              expect(error.path).to eq(path)
              expect(error.message).to include(path)
            end
          end

          it "reports a path that cannot be read as a read error that is not marked missing" do
            expect { Document.read(@dir) }.to raise_error(ReadError) do |error|
              expect(error.missing).to be false
              expect(error.path).to eq(@dir)
            end
          end

          it "reports unparseable content as a read error that is not marked missing" do
            path = File.join(@dir, "bad.json")
            File.write(path, '{"flagValues"')

            expect { Document.read(path) }.to raise_error(ReadError) do |error|
              expect(error.missing).to be false
              expect(error.message).to include("error parsing file")
              expect(error.message).to include(path)
            end
          end

          it "reports a document that is not an object as a read error" do
            path = File.join(@dir, "scalar.yaml")
            File.write(path, "just a string\n")

            expect { Document.read(path) }.to raise_error(ReadError, /must be an object/)
          end
        end
      end

      describe "make_flag_with_value" do
        it "builds a flag that is on and serves the value as its only variation" do
          flag = FileData.make_flag_with_value("flag1", "value1")

          expect(flag).to eq({
            key: "flag1",
            on: true,
            version: 1,
            fallthrough: { variation: 0 },
            variations: ["value1"],
          })
        end

        it "uses the given version" do
          expect(FileData.make_flag_with_value("flag1", true, 7)[:version]).to eq(7)
        end

        it "builds a flag that is off and serves the value as its off variation when asked" do
          flag = FileData.make_flag_with_value("flag1", "value1", 3, off: true)

          expect(flag).to eq({
            key: "flag1",
            on: false,
            version: 3,
            offVariation: 0,
            variations: ["value1"],
          })
        end
      end

      describe "absolute_paths" do
        it "converts relative paths to absolute paths and accepts a single string" do
          expect(FileData.absolute_paths("a/b.json")).to eq([File.absolute_path("a/b.json")])
          expect(FileData.absolute_paths(["/x/y.json", "z.json"])).to eq(["/x/y.json", File.absolute_path("z.json")])
        end
      end
    end
  end
end
