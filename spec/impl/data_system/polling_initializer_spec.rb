# frozen_string_literal: true

require "spec_helper"
require "ldclient-rb/impl/data_system/polling"
require "ldclient-rb/interfaces"

module LaunchDarkly
  module Impl
    module DataSystem
      RSpec.describe ".fdv1_fallback_requested?" do
        it "matches the canonical mixed-case header" do
          headers = { 'X-LD-FD-Fallback' => 'true' }
          expect(LaunchDarkly::Impl::DataSystem.fdv1_fallback_requested?(headers)).to be true
        end

        it "matches the downcased header (HTTPPollingRequester#fetch normalizes casing)" do
          headers = { 'x-ld-fd-fallback' => 'true' }
          expect(LaunchDarkly::Impl::DataSystem.fdv1_fallback_requested?(headers)).to be true
        end

        it "matches arbitrary mixed-case header keys" do
          headers = { 'X-Ld-Fd-Fallback' => 'true' }
          expect(LaunchDarkly::Impl::DataSystem.fdv1_fallback_requested?(headers)).to be true
        end

        it "returns false when the header is absent" do
          expect(LaunchDarkly::Impl::DataSystem.fdv1_fallback_requested?({})).to be false
        end

        it "returns false when the header value is not 'true'" do
          headers = { 'X-LD-FD-Fallback' => 'false' }
          expect(LaunchDarkly::Impl::DataSystem.fdv1_fallback_requested?(headers)).to be false
        end

        it "returns false when the headers object is nil" do
          expect(LaunchDarkly::Impl::DataSystem.fdv1_fallback_requested?(nil)).to be false
        end

        it "works against case-insensitive containers (HTTP::Headers shape)" do
          # The ld-eventsource gem hands us an HTTP::Headers instance whose []
          # accessor is case-insensitive but which does not implement
          # each_pair. Simulate that shape so the helper is exercised against
          # exactly the API surface that broke contract tests on PR #381.
          ci_container = Class.new do
            def initialize(values)
              @values = values
            end

            def [](name)
              @values[name.to_s.downcase]
            end
          end
          headers = ci_container.new('x-ld-fd-fallback' => 'true')
          expect(LaunchDarkly::Impl::DataSystem.fdv1_fallback_requested?(headers)).to be true
        end
      end

      RSpec.describe PollingDataSource do
        let(:logger) { double("Logger", info: nil, warn: nil, error: nil, debug: nil) }

        class MockExceptionThrowingPollingRequester
          include LaunchDarkly::DataSystem::Requester

          def fetch(selector)
            raise "This is a mock exception for testing purposes."
          end
        end

        class MockPollingRequester
          include LaunchDarkly::DataSystem::Requester

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

          it "surfaces fallback_to_fdv1 on a successful response with the fallback header" do
            # Server-directed FDv1 Fallback Directive may ride along on a 200 response that also
            # carries a valid payload. The SDK must apply the payload AND surface the fallback
            # signal so the data system can transition to the FDv1 Fallback Synchronizer.
            change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes
            headers = { LD_FD_FALLBACK_HEADER => 'true' }
            mock_requester = MockPollingRequester.new(
              LaunchDarkly::Result.success([change_set, headers])
            )
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            fetch_result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(fetch_result).to be_a(LaunchDarkly::Interfaces::DataSystem::FetchResult)
            expect(fetch_result.success?).to be true
            expect(fetch_result.fallback_to_fdv1).to be true
            expect(fetch_result.value).to be_a(LaunchDarkly::Interfaces::DataSystem::Basis)
          end

          it "surfaces fallback_to_fdv1 on an error response with the fallback header" do
            # Even on a 500 response, the fallback header should be surfaced so the caller can
            # branch on the directive before the recoverable-error logic kicks in.
            headers_with_fallback = { LD_FD_FALLBACK_HEADER => 'true' }
            error_result = LaunchDarkly::Result.fail(
              "failure message",
              LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(500),
              headers_with_fallback
            )
            mock_requester = MockPollingRequester.new(error_result)
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            fetch_result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(fetch_result).to be_a(LaunchDarkly::Interfaces::DataSystem::FetchResult)
            expect(fetch_result.success?).to be false
            expect(fetch_result.fallback_to_fdv1).to be true
          end

          it "honors the fallback header regardless of case" do
            # The HTTPPollingRequester downcases response header keys before
            # handing them off, but other code paths (and other HTTP clients)
            # may keep the canonical mixed case. Header lookup must be
            # case-insensitive or the directive silently disappears against a
            # perfectly valid response -- this is the bug that the contract
            # tests caught against the initializer-phase fix.
            change_set = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.no_changes
            headers = { 'x-ld-fd-fallback' => 'true' } # downcased -- mirrors HTTPPollingRequester
            mock_requester = MockPollingRequester.new(
              LaunchDarkly::Result.success([change_set, headers])
            )
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            fetch_result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(fetch_result.success?).to be true
            expect(fetch_result.fallback_to_fdv1).to be true
          end

          it "honors the fallback header on error responses with downcased keys" do
            headers_with_fallback = { 'x-ld-fd-fallback' => 'true' }
            error_result = LaunchDarkly::Result.fail(
              "failure message",
              LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(500),
              headers_with_fallback
            )
            mock_requester = MockPollingRequester.new(error_result)
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            fetch_result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(fetch_result.success?).to be false
            expect(fetch_result.fallback_to_fdv1).to be true
          end

          it "reports fallback_to_fdv1 as false when the header is absent on error" do
            mock_requester = MockPollingRequester.new(
              LaunchDarkly::Result.fail(
                "failure message",
                LaunchDarkly::Impl::DataSource::UnexpectedResponseError.new(500)
              )
            )
            ds = PollingDataSource.new(1.0, mock_requester, logger)

            fetch_result = ds.fetch(MockSelectorStore.new(LaunchDarkly::Interfaces::DataSystem::Selector.no_selector))

            expect(fetch_result.success?).to be false
            expect(fetch_result.fallback_to_fdv1).to be false
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
