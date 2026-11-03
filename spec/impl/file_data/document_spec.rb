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
            document = Document.parse(<<~JSON, format: :json)
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
            document = Document.parse(<<~YAML, format: :yaml)
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

          it "treats empty YAML content as a document with no entries" do
            ["", " \n\r\n", "# a comment\n", "---\n", "~\n"].each do |content|
              document = Document.parse(content, format: :yaml)

              expect(document.flags).to eq({})
              expect(document.flag_values).to eq({})
              expect(document.segments).to eq({})
            end
          end

          it "returns NONE for YAML that is only a null, and a document for {} or a member that is null" do
            ["", "# a comment\n", "---\n", "~\n"].each do |content|
              expect(Document.parse(content, format: :yaml)).to be(Document::NONE)
            end
            ["{}\n", "flagValues:\n"].each do |content|
              document = Document.parse(content, format: :yaml)

              expect(document).not_to be(Document::NONE)
              expect(document.flag_values).to eq({})
            end
            expect(Document.parse("{}", format: :json)).not_to be(Document::NONE)
          end

          it "treats YAML with only white space, including a tab, vertical tab or form feed, as no entries" do
            expect(Document.parse("\t\n", format: :yaml)).to be(Document::NONE)
            expect(Document.parse(" \v\f\t\r\n", format: :yaml)).to be(Document::NONE)
          end

          it "rejects content that is not valid UTF-8, in both formats" do
            latin1 = (+"{\"flagValues\": {\"flag1\": \"caf\xE9\"}}").force_encoding(Encoding::UTF_8)
            [:json, :yaml].each do |format|
              expect { Document.parse(latin1, format: format) }.to raise_error(ArgumentError, "the file is not valid UTF-8")
            end
          end

          it "rejects empty JSON content, which is not a JSON document" do
            ["", " \n\r\n\t"].each do |content|
              expect { Document.parse(content, format: :json) }
                .to raise_error(ArgumentError, "the file has no content, which is not a JSON document")
            end
          end

          it "treats a document with no known sections as a document with no entries" do
            [[:json, "{}"], [:yaml, "{}"], [:yaml, "other: 1\n"]].each do |format, content|
              document = Document.parse(content, format: format)

              expect(document.flags).to eq({})
              expect(document.flag_values).to eq({})
              expect(document.segments).to eq({})
            end
          end

          it "rejects a document that is not an object" do
            [:json, :yaml].each do |format|
              expect { Document.parse("\"hello\"", format: format) }.to raise_error(ArgumentError, /must be an object/)
              expect { Document.parse("[1, 2]", format: format) }.to raise_error(ArgumentError, /must be an object/)
            end
            expect { Document.parse("null", format: :json) }.to raise_error(ArgumentError, /must be an object/)
            expect { Document.parse("false", format: :yaml) }.to raise_error(ArgumentError, /must be an object/)
          end

          it "rejects a section that is not an object" do
            expect { Document.parse('{"flags": []}', format: :json) }.to raise_error(ArgumentError, /"flags" must be an object/)
            expect { Document.parse('{"flagValues": 3}', format: :json) }.to raise_error(ArgumentError, /"flagValues" must be an object/)
            expect { Document.parse('{"segments": "x"}', format: :json) }.to raise_error(ArgumentError, /"segments" must be an object/)
          end

          it "symbolizes keys that YAML parsed as numbers" do
            document = Document.parse("flagValues:\n  123: true\n", format: :yaml)

            expect(document.flag_values).to eq({ "123": true })
          end

          it "reads JSON numbers as JSON does" do
            document = Document.parse('{"flagValues": {"flag1": 1e3, "flag2": 12}}', format: :json)

            expect(document.flag_values).to eq({ flag1: 1000.0, flag2: 12 })
          end

          it "raises a syntax error for content that cannot be parsed" do
            expect { Document.parse('{"flagValues"', format: :json) }.to raise_error(JSON::ParserError)
            expect { Document.parse('{"flagValues": {}} extra', format: :json) }.to raise_error(JSON::ParserError)
            expect { Document.parse("flagValues: [", format: :yaml) }.to raise_error(Psych::SyntaxError)
          end

          it "rejects a YAML document as JSON" do
            expect { Document.parse("flagValues:\n  flag1: true\n", format: :json) }.to raise_error(JSON::ParserError)
          end

          it "rejects an unknown format" do
            expect { Document.parse("{}", format: :toml) }.to raise_error(ArgumentError, /unknown file format/)
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

          it "reads a file as YAML when its name ends in .yaml or .yml, in any case" do
            ["flags.yaml", "flags.yml", "flags.YAML", "flags.Yml"].each do |name|
              path = File.join(@dir, name)
              File.write(path, "flagValues:\n  flag1: true\n")

              expect(Document.read(path).flag_values).to eq({ flag1: true })
            end
          end

          it "reads any other file as JSON" do
            ["flags.json", "flags", "flags.txt", "flags.yaml.json"].each do |name|
              path = File.join(@dir, name)
              File.write(path, "flagValues:\n  flag1: true\n")

              expect { Document.read(path) }.to raise_error(ReadError, /error parsing file/)
            end
          end

          it "reports an empty file as a read error when it is JSON, and as no entries when it is YAML" do
            ["flags.json", "flags"].each do |name|
              path = File.join(@dir, name)
              File.write(path, "")

              expect { Document.read(path) }.to raise_error(ReadError, /the file has no content, which is not a JSON document/)
            end

            path = File.join(@dir, "flags.yaml")
            File.write(path, "")
            expect(Document.read(path).flag_values).to eq({})
          end

          it "reads a file that starts with a byte order mark" do
            path = File.join(@dir, "flags.json")
            File.binwrite(path, "\xEF\xBB\xBF{\"flagValues\": {\"flag1\": \"caf\xC3\xA9\"}}")

            expect(Document.read(path).flag_values).to eq({ flag1: "caf\u00e9" })
          end

          it "reports a file encoded in UTF-16 or UTF-32 as a read error" do
            path = File.join(@dir, "flags.json")
            content = '{"flagValues": {"flag1": true}}'
            ["\xFF\xFE".b + content.encode("UTF-16LE").b, "\xFE\xFF".b + content.encode("UTF-16BE").b,
             "\xFF\xFE\x00\x00".b + content.encode("UTF-32LE").b].each do |bytes|
              File.binwrite(path, bytes)

              expect { Document.read(path) }.to raise_error(ReadError, /encoded in UTF-16 or UTF-32; data files must be UTF-8/)
            end
          end

          it "reads a file as UTF-8 whatever the default external encoding" do
            path = File.join(@dir, "flags.yaml")
            File.binwrite(path, "flagValues:\n  flag1: caf\xC3\xA9\n")
            previous = Encoding.default_external
            begin
              Encoding.default_external = Encoding::US_ASCII
              expect(Document.read(path).flag_values).to eq({ flag1: "caf\u00e9" })
            ensure
              Encoding.default_external = previous
            end
          end

          it "reads a file that holds only a byte order mark as empty" do
            path = File.join(@dir, "flags.json")
            File.binwrite(path, "\xEF\xBB\xBF")

            expect(FileData.read_file(path)).to eq("")
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

      describe "format_of" do
        it "chooses YAML for a name that ends in .yaml or .yml, in any case, and JSON otherwise" do
          expect(FileData.format_of("/a/flags.yaml")).to eq(:yaml)
          expect(FileData.format_of("/a/flags.YML")).to eq(:yaml)
          expect(FileData.format_of("/a/flags.json")).to eq(:json)
          expect(FileData.format_of("/a.yaml/flags")).to eq(:json)
          expect(FileData.format_of("/a/flags.yaml.bak")).to eq(:json)
        end
      end

      describe "blank?" do
        it "is true for content that is empty or only white space" do
          expect(FileData.blank?("")).to be true
          expect(FileData.blank?(" \t\r\n\f\v")).to be true
          expect(FileData.blank?(" {}")).to be false
          expect(FileData.blank?("# comment")).to be false
          expect(FileData.blank?("\xFF".b)).to be false
        end
      end

      describe "make_flag_with_value" do
        it "builds a flag that is on and serves the value as its fallthrough" do
          flag = FileData.make_flag_with_value("flag1", "value1")

          expect(flag).to eq({
            key: "flag1",
            on: true,
            version: 1,
            fallthrough: { variation: 0 },
            variations: ["value1"],
          })
        end
      end

      describe "absolute_paths" do
        it "converts relative paths to absolute paths and accepts a single string" do
          absolute = File.absolute_path("/x/y.json")

          expect(FileData.absolute_paths("a/b.json")).to eq([File.absolute_path("a/b.json")])
          expect(FileData.absolute_paths([absolute, "z.json"])).to eq([absolute, File.absolute_path("z.json")])
        end
      end
    end
  end
end
