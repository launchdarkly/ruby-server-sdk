# frozen_string_literal: true

require "spec_helper"
require "ldclient-rb/impl/data_system/polling"
require "ldclient-rb/interfaces"

module LaunchDarkly
  module Impl
    module DataSystem
      RSpec.describe PollingDataSource do
        let(:logger) { double("Logger", info: nil, warn: nil, error: nil, debug: nil) }

        class MockExceptionThrowingPollingRequester
          include Requester

          def fetch(selector)
            raise "This is a mock exception for testing purposes."
          end
        end

        class MockPollingRequester
          include Requester

          def initialize(result)
            @result = result
          end

          def fetch(selector)
            @result
          end
        end

        class MockSelectorStore
          include LaunchDarkly::Interfaces::DataSystem::SelectorStore

          def initialize(selector)
            @selector = selector
          end

          def selector
            @selector
          end
        end

        describe "#fetch" do
          it "polling has a name" do
            mock_requester = MockPollingRequester.new(LaunchDarkly::Result.fail("failure message"))
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            expect(ds.name).to eq("PollingDataSourceV2")
          end

          it "error is returned on failure" do
            mock_requester = MockPollingRequester.new(LaunchDarkly::Result.fail("failure message"))
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(result).not_to be_nil
            expect(result.success?).to eq(false)
            expect(result.error).to eq("failure message")
          end

          it "error is recoverable" do
            mock_requester = MockPollingRequester.new(
              LaunchDarkly::Result.fail(
                "failure message",
                LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(408)
              )
            )
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(result).not_to be_nil
            expect(result.success?).to eq(false)
          end

          it "error is unrecoverable" do
            mock_requester = MockPollingRequester.new(
              LaunchDarkly::Result.fail(
                "failure message",
                LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(401)
              )
            )
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(result).not_to be_nil
            expect(result.success?).to eq(false)
          end

          it "handles transfer none" do
            mock_requester = MockPollingRequester.new(
              LaunchDarkly::Result.success([LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes, {}])
            )
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(result).not_to be_nil
            expect(result.success?).to eq(true)
            expect(result.value.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE)
            expect(result.value.change_set.changes).to eq([])
            expect(result.value.persist).to eq(false)
          end

          it "handles uncaught exception" do
            mock_requester = MockExceptionThrowingPollingRequester.new
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(result).not_to be_nil
            expect(result.success?).to eq(false)
            expect(result.error).to include("Exception encountered when updating flags")
          end

          it "handles transfer full" do
            payload_str = '{"events":[ {"event":"server-intent","data":{"payloads":[ {"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":461,"intentCode":"xfer-full","reason":"payload-missing"}]}},{"event": "put-object","data": {"key":"sample-feature","kind":"flag","version":461,"object":{"key":"sample-feature","on":false,"prerequisites":[],"targets":[],"contextTargets":[],"rules":[],"fallthrough":{"variation":0},"offVariation":1,"variations":[true,false],"clientSideAvailability":{"usingMobileKey":false,"usingEnvironmentId":false},"clientSide":false,"salt":"9945e63a79a44787805b79728fee1926","trackEvents":false,"trackEventsFallthrough":false,"debugEventsUntilDate":null,"version":112,"deleted":false}}},{"event":"payload-transferred","data":{"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:461)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":461}}]}' # rubocop:disable Layout/LineLength
            change_set_result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
            expect(change_set_result.success?).to eq(true)

            mock_requester = MockPollingRequester.new(LaunchDarkly::Result.success([change_set_result.value, {}]))
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(result).not_to be_nil
            expect(result.success?).to eq(true)
            expect(result.value.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
            expect(result.value.change_set.changes.length).to eq(1)
            expect(result.value.persist).to eq(true)
          end

          it "handles transfer changes" do
            payload_str = '{"events":[{"event": "server-intent","data": {"payloads":[{"id":"5A46PZ79FQ9D08YYKT79DECDNV","target":462,"intentCode":"xfer-changes","reason":"stale"}]}},{"event": "put-object","data": {"key":"sample-feature","kind":"flag","version":462,"object":{"key":"sample-feature","on":true,"prerequisites":[],"targets":[],"contextTargets":[],"rules":[],"fallthrough":{"variation":0},"offVariation":1,"variations":[true,false],"clientSideAvailability":{"usingMobileKey":false,"usingEnvironmentId":false},"clientSide":false,"salt":"9945e63a79a44787805b79728fee1926","trackEvents":false,"trackEventsFallthrough":false,"debugEventsUntilDate":null,"version":113,"deleted":false}}},{"event": "payload-transferred","data": {"state":"(p:5A46PZ79FQ9D08YYKT79DECDNV:462)","id":"5A46PZ79FQ9D08YYKT79DECDNV","version":462}}]}' # rubocop:disable Layout/LineLength
            change_set_result = LaunchDarkly::Impl::DataSystem.polling_payload_to_changeset(JSON.parse(payload_str, symbolize_names: true))
            expect(change_set_result.success?).to eq(true)

            mock_requester = MockPollingRequester.new(LaunchDarkly::Result.success([change_set_result.value, {}]))
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(result).not_to be_nil
            expect(result.success?).to eq(true)
            expect(result.value.change_set.intent_code).to eq(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_CHANGES)
            expect(result.value.change_set.changes.length).to eq(1)
            expect(result.value.persist).to eq(true)
          end
        end
      end
    end
  end
end
