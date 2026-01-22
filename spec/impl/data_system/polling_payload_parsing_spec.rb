# frozen_string_literal: true

require "spec_helper"
require "ldclient-rb/impl/data_system/polling"
require "ldclient-rb/interfaces"
require "json"

module LaunchDarkly
  module Impl
    module DataSystem
      RSpec.describe ".polling_payload_to_changeset" do
        it "payload is missing events key" do
          data = {}
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(data)
          expect(result.success?).to eq(false)
        end

        it "payload events value is invalid" do
          data = { events: "not a list" }
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(data)
          expect(result.success?).to eq(false)
        end

        it "payload event is invalid" do
          data = { events: ["this should be a dictionary"] }
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(data)
          expect(result.success?).to eq(false)
        end

        it "missing protocol events" do
          data = { events: [] }
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(data)
          expect(result.success?).to eq(false)
        end

        it "transfer none" do
          payload_str = '{"events":[{"event": "server-intent","data": {"payloads":[{"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":462,"intentCode":"none","reason":"up-to-date"}]}}]}'
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))

          expect(result).not_to be_nil
          expect(result.value.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE)
          expect(result.value.changes.length).to eq(0)
          expect(result.value.selector).not_to be_nil
          expect(result.value.selector.defined?).to eq(false)
        end

        it "transfer full with empty payload" do
          payload_str = '{"events":[ {"event":"server-intent","data":{"payloads":[ {"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":461,"intentCode":"xfer-full","reason":"payload-missing"}]}},{"event":"payload-transferred","data":{"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:461)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":461}}]}' # rubocop:disable Layout/LineLength
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))

          expect(result).not_to be_nil
          expect(result.value.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
          expect(result.value.changes.length).to eq(0)
          expect(result.value.selector).not_to be_nil
          expect(result.value.selector.state).to eq("(p:5A46PZ79FQ9D08YYKT79DECDNV:461)")
          expect(result.value.selector.version).to eq(461)
        end

        it "server intent decoding fails" do
          payload_str = '{"events":[ {"event":"server-intent","data":{}},{"event":"payload-transferred","data":{"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:461)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":461}}]}' # rubocop:disable Layout/LineLength
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
          expect(result.success?).to eq(false)
        end

        it "processes put object" do
          payload_str = '{"events":[ {"event":"server-intent","data":{"payloads":[ {"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":461,"intentCode":"xfer-full","reason":"payload-missing"}]}},{"event": "put-object","data": {"key":"sampleflag","kind":"flag","version":461,"object":{"key":"sampleflag","on":false,"prerequisites":[],"targets":[],"contextTargets":[],"rules":[],"fallthrough":{"variation":0},"offVariation":1,"variations":[true,false],"clientSideAvailability":{"usingMobileKey":false,"usingEnvironmentId":false},"clientSide":false,"salt":"9945e63a79a44787805b79728fee1926","trackEvents":false,"trackEventsFallthrough":false,"debugEventsUntilDate":null,"version":112,"deleted":false}}},{"event":"payload-transferred","data":{"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:461)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":461}}]}' # rubocop:disable Layout/LineLength
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
          expect(result).not_to be_nil

          expect(result.value.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
          expect(result.value.changes.length).to eq(1)

          expect(result.value.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT)
          expect(result.value.changes[0].kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG)
          expect(result.value.changes[0].key).to eq(:sampleflag)
          expect(result.value.changes[0].version).to eq(461)
          expect(result.value.changes[0].object).to be_a(Hash)

          expect(result.value.selector).not_to be_nil
          expect(result.value.selector.state).to eq("(p:5A46PZ79FQ9D08YYKT79DECDNV:461)")
          expect(result.value.selector.version).to eq(461)
        end

        it "processes delete object" do
          payload_str = '{"events":[ {"event":"server-intent","data":{"payloads":[ {"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":461,"intentCode":"xfer-full","reason":"payload-missing"}]}},{"event": "delete-object","data": {"key":"sampleflag","kind":"flag","version":461}},{"event":"payload-transferred","data":{"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:461)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":461}}]}' # rubocop:disable Layout/LineLength
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
          expect(result).not_to be_nil

          expect(result.value.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
          expect(result.value.changes.length).to eq(1)

          expect(result.value.changes[0].action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE)
          expect(result.value.changes[0].kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG)
          expect(result.value.changes[0].key).to eq(:sampleflag)
          expect(result.value.changes[0].version).to eq(461)
          expect(result.value.changes[0].object).to be_nil

          expect(result.value.selector).not_to be_nil
          expect(result.value.selector.state).to eq("(p:5A46PZ79FQ9D08YYKT79DECDNV:461)")
          expect(result.value.selector.version).to eq(461)
        end

        it "handles invalid put object" do
          payload_str = '{"events":[ {"event":"server-intent","data":{"payloads":[ {"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":461,"intentCode":"xfer-full","reason":"payload-missing"}]}},{"event": "put-object","data": {}},{"event":"payload-transferred","data":{"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:461)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":461}}]}' # rubocop:disable Layout/LineLength
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
          expect(result.success?).to eq(false)
        end

        it "handles invalid delete object" do
          payload_str = '{"events":[ {"event":"server-intent","data":{"payloads":[ {"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":461,"intentCode":"xfer-full","reason":"payload-missing"}]}},{"event": "delete-object","data": {}},{"event":"payload-transferred","data":{"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:461)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":461}}]}' # rubocop:disable Layout/LineLength
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
          expect(result.success?).to eq(false)
        end

        it "handles invalid payload transferred" do
          payload_str = '{"events":[ {"event":"server-intent","data":{"payloads":[ {"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":461,"intentCode":"xfer-full","reason":"payload-missing"}]}},{"event":"payload-transferred","data":{}}]}' # rubocop:disable Layout/LineLength
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
          expect(result.success?).to eq(false)
        end

        it "fails if starts with transferred" do
          payload_str = '{"events":[ {"event":"payload-transferred","data":{"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:461)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":461}},{"event":"server-intent","data":{"payloads":[ {"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":461,"intentCode":"xfer-full","reason":"payload-missing"}]}},{"event": "put-object","data": {"key":"sampleflag","kind":"flag","version":461,"object":{"key":"sampleflag","on":false,"prerequisites":[],"targets":[],"contextTargets":[],"rules":[],"fallthrough":{"variation":0},"offVariation":1,"variations":[true,false],"clientSideAvailability":{"usingMobileKey":false,"usingEnvironmentId":false},"clientSide":false,"salt":"9945e63a79a44787805b79728fee1926","trackEvents":false,"trackEventsFallthrough":false,"debugEventsUntilDate":null,"version":112,"deleted":false}}}]}' # rubocop:disable Layout/LineLength
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
          expect(result.success?).to eq(false)
        end

        it "fails if starts with put" do
          payload_str = '{"events":[ {"event": "put-object","data": {"key":"sampleflag","kind":"flag","version":461,"object":{"key":"sampleflag","on":false,"prerequisites":[],"targets":[],"contextTargets":[],"rules":[],"fallthrough":{"variation":0},"offVariation":1,"variations":[true,false],"clientSideAvailability":{"usingMobileKey":false,"usingEnvironmentId":false},"clientSide":false,"salt":"9945e63a79a44787805b79728fee1926","trackEvents":false,"trackEventsFallthrough":false,"debugEventsUntilDate":null,"version":112,"deleted":false}}},{"event":"payload-transferred","data":{"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:461)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":461}},{"event":"server-intent","data":{"payloads":[ {"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":461,"intentCode":"xfer-full","reason":"payload-missing"}]}}]}' # rubocop:disable Layout/LineLength
          result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
          expect(result.success?).to eq(false)
        end
      end

      RSpec.describe ".fdv1_polling_payload_to_changeset" do
        it "handles empty flags and segments" do
          data = {
            flags: {},
            segments: {},
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result).not_to be_nil

          expect(result.value.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
          expect(result.value.changes.length).to eq(0)
          expect(result.value.selector).not_to be_nil
          expect(result.value.selector.defined?).to eq(false)
        end

        it "handles single flag" do
          data = {
            flags: {
              testflag: {
                key: "testflag",
                version: 1,
                on: true,
                variations: [true, false],
              },
            },
            segments: {},
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result).not_to be_nil

          expect(result.value.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
          expect(result.value.changes.length).to eq(1)

          change = result.value.changes[0]
          expect(change.action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT)
          expect(change.kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG)
          expect(change.key).to eq(:testflag)
          expect(change.version).to eq(1)
        end

        it "handles multiple flags" do
          data = {
            flags: {
              'flag-1': { key: "flag-1", version: 1, on: true },
              'flag-2': { key: "flag-2", version: 2, on: false },
              'flag-3': { key: "flag-3", version: 3, on: true },
            },
            segments: {},
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result).not_to be_nil

          expect(result.value.changes.length).to eq(3)
          flag_keys = result.value.changes.map(&:key).to_set
          expect(flag_keys).to eq(Set[:"flag-1", :"flag-2", :"flag-3"])
        end

        it "handles single segment" do
          data = {
            flags: {},
            segments: {
              testsegment: {
                key: "testsegment",
                version: 5,
                included: ["user1", "user2"],
              },
            },
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result).not_to be_nil

          expect(result.value.changes.length).to eq(1)
          change = result.value.changes[0]
          expect(change.action).to eq(LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT)
          expect(change.kind).to eq(LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT)
          expect(change.key).to eq(:testsegment)
          expect(change.version).to eq(5)
        end

        it "handles flags and segments" do
          data = {
            flags: {
              'flag-1': { key: "flag-1", version: 1, on: true },
              'flag-2': { key: "flag-2", version: 2, on: false },
            },
            segments: {
              'segment-1': { key: "segment-1", version: 10 },
              'segment-2': { key: "segment-2", version: 20 },
            },
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result).not_to be_nil

          expect(result.value.changes.length).to eq(4)

          flag_changes = result.value.changes.select { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG }
          segment_changes = result.value.changes.select { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT }

          expect(flag_changes.length).to eq(2)
          expect(segment_changes.length).to eq(2)
        end

        it "fails when flags is not dict" do
          data = {
            flags: "not a dict",
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result.success?).to eq(false)
        end

        it "fails when segments is not dict" do
          data = {
            flags: {},
            segments: "not a dict",
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result.success?).to eq(false)
        end

        it "fails when flag value is not dict" do
          data = {
            flags: {
              "bad-flag" => "not a dict",
            },
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result.success?).to eq(false)
        end

        it "fails when flag missing version" do
          data = {
            flags: {
              "no-version-flag" => {
                key: "no-version-flag",
                on: true,
              },
            },
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result.success?).to eq(false)
        end

        it "fails when segment missing version" do
          data = {
            flags: {},
            segments: {
              "no-version-segment" => {
                key: "no-version-segment",
                included: [],
              },
            },
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result.success?).to eq(false)
        end

        it "works with only flags, no segments key" do
          data = {
            flags: {
              testflag: { key: "testflag", version: 1, on: true },
            },
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result).not_to be_nil

          expect(result.value.changes.length).to eq(1)
          expect(result.value.changes[0].key).to eq(:testflag)
        end

        it "works with only segments, no flags key" do
          data = {
            segments: {
              testsegment: { key: "testsegment", version: 1 },
            },
          }
          result = LaunchDarkly::Impl::DataSystem.fdv1_polling_payload_to_changeset(data)
          expect(result).not_to be_nil

          expect(result.value.changes.length).to eq(1)
          expect(result.value.changes[0].key).to eq(:testsegment)
        end
      end
    end
  end
end
