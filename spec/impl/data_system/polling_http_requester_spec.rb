# frozen_string_literal: true

require "spec_helper"
require "http_util"
require "ldclient-rb/impl/data_system/polling"
require "ldclient-rb/interfaces"
require "json"
require "stringio"
require "zlib"

module LaunchDarkly
  module Impl
    module DataSystem
      module PollingHTTPRequesterSpec
        SDK_KEY = "secret"

        def self.fdv2_payload(flag_key, version)
          {
            events: [
              {
                event: "server-intent",
                data: { payloads: [{ id: "id", target: version, intentCode: "xfer-full", reason: "payload-missing" }] },
              },
              {
                event: "put-object",
                data: { key: flag_key, kind: "flag", version: version, object: { key: flag_key, version: version } },
              },
              {
                event: "payload-transferred",
                data: { state: "(p:id:#{version})", id: "id", version: version },
              },
            ],
          }.to_json
        end

        def self.fdv1_payload(flag_key, version)
          { flags: { flag_key => { key: flag_key, version: version } }, segments: {} }.to_json
        end

        def self.gzip(body)
          io = StringIO.new
          gz = Zlib::GzipWriter.new(io)
          gz.write(body)
          gz.close
          io.string
        end
      end

      [
        { requester_class: HTTPPollingRequester, path: FDV2_POLLING_ENDPOINT, payload: PollingHTTPRequesterSpec.method(:fdv2_payload) },
        { requester_class: HTTPFDv1PollingRequester, path: FDV1_POLLING_ENDPOINT, payload: PollingHTTPRequesterSpec.method(:fdv1_payload) },
      ].each do |params|
        requester_class = params[:requester_class]
        path = params[:path]
        payload = params[:payload]

        RSpec.describe requester_class do
          let(:sdk_key) { PollingHTTPRequesterSpec::SDK_KEY }

          def with_requester(base_uri, config_opts = {})
            http_config = HttpConfigOptions.new(base_uri: base_uri)
            config = Config.new({ logger: $null_log }.merge(config_opts))
            requester = described_class.new(sdk_key, http_config, config)
            begin
              yield requester
            ensure
              requester.stop
            end
          end

          def change_keys(result)
            result.value.changes.map { |change| change.key.to_s }
          end

          def setup_etag_response(server, body, etag)
            server.setup_response("/") do |_, res|
              res.status = 200
              res.body = body
              res["ETag"] = etag
            end
          end

          it "uses the expected URI and headers" do
            with_server do |server|
              server.setup_ok_response("/", payload.call("flagkey", 1))
              with_requester(server.base_uri.to_s, application: { id: "id", version: "version" }) do |requester|
                requester.fetch(nil)
              end

              expect(server.requests.count).to eq 1
              expect(server.requests[0].unparsed_uri).to eq path
              expect(server.requests[0].header).to include({
                "authorization" => [sdk_key],
                "user-agent" => ["RubyClient/" + VERSION],
                "accept-encoding" => ["gzip"],
                "x-launchdarkly-tags" => ["application-id/id application-version/version"],
              })
            end
          end

          it "sends the wrapper header if configured" do
            with_server do |server|
              server.setup_ok_response("/", payload.call("flagkey", 1))
              with_requester(server.base_uri.to_s, wrapper_name: "MyWrapper", wrapper_version: "1.0") do |requester|
                requester.fetch(nil)
              end

              expect(server.requests.count).to eq 1
              expect(server.requests[0].header).to include({ "x-launchdarkly-wrapper" => ["MyWrapper/1.0"] })
            end
          end

          it "parses the response into a change set" do
            with_server do |server|
              server.setup_ok_response("/", payload.call("flagkey", 1), "application/json")
              with_requester(server.base_uri.to_s) do |requester|
                result = requester.fetch(nil)

                expect(result.success?).to be true
                expect(result.value.intent_code).to eq Interfaces::DataSystem::IntentCode::TRANSFER_FULL
                expect(change_keys(result)).to eq ["flagkey"]
              end
            end
          end

          it "returns the response headers" do
            with_server do |server|
              server.setup_ok_response("/", payload.call("flagkey", 1), "application/json", { "X-LD-EnvID" => "env-abc" })
              with_requester(server.base_uri.to_s) do |requester|
                result = requester.fetch(nil)

                expect(result.success?).to be true
                expect(result.headers["x-ld-envid"]).to eq "env-abc"
              end
            end
          end

          it "decodes a gzip-compressed response" do
            with_server do |server|
              server.setup_response("/") do |_, res|
                res.status = 200
                res["Content-Encoding"] = "gzip"
                res.body = PollingHTTPRequesterSpec.gzip(payload.call("flagkey", 1))
              end
              with_requester(server.base_uri.to_s) do |requester|
                result = requester.fetch(nil)

                expect(result.success?).to be true
                expect(change_keys(result)).to eq ["flagkey"]
              end
            end
          end

          it "sends the ETag from the previous response and treats 304 as no change" do
            with_server do |server|
              with_requester(server.base_uri.to_s) do |requester|
                setup_etag_response(server, payload.call("flagkey", 1), "abc")
                expect(requester.fetch(nil).success?).to be true
                expect(server.requests[0].header).not_to include("if-none-match")

                server.setup_status_response("/", 304)
                result = requester.fetch(nil)

                expect(server.requests.count).to eq 2
                expect(server.requests[1].header).to include({ "if-none-match" => ["abc"] })
                expect(result.success?).to be true
                expect(result.value.intent_code).to eq Interfaces::DataSystem::IntentCode::TRANSFER_NONE
                expect(result.value.changes).to be_empty
              end
            end
          end

          it "replaces the stored ETag when a response has a new ETag" do
            with_server do |server|
              with_requester(server.base_uri.to_s) do |requester|
                setup_etag_response(server, payload.call("flag1", 1), "abc")
                expect(change_keys(requester.fetch(nil))).to eq ["flag1"]

                setup_etag_response(server, payload.call("flag2", 2), "xyz")
                expect(change_keys(requester.fetch(nil))).to eq ["flag2"]
                expect(server.requests[1].header).to include({ "if-none-match" => ["abc"] })

                server.setup_status_response("/", 304)
                requester.fetch(nil)
                expect(server.requests.count).to eq 3
                expect(server.requests[2].header).to include({ "if-none-match" => ["xyz"] })
              end
            end
          end

          it "returns a failed result for an error status" do
            with_server do |server|
              server.setup_status_response("/", 400, { "X-LD-EnvID" => "env-abc" })
              with_requester(server.base_uri.to_s) do |requester|
                result = requester.fetch(nil)

                expect(result.success?).to be false
                expect(result.exception).to be_a(UnexpectedResponseError)
                expect(result.exception.status).to eq 400
                expect(result.headers["x-ld-envid"]).to eq "env-abc"
              end
            end
          end

          it "can use a proxy server" do
            # The stub server acts as the proxy. The request reaches it instead of the fake target.
            fake_target_uri = "http://request-will-not-really-go-here.invalid"
            with_server do |proxy|
              proxy.setup_ok_response(path, payload.call("flagkey", 1), "application/json")
              begin
                ENV["http_proxy"] = proxy.base_uri.to_s
                with_requester(fake_target_uri) do |requester|
                  result = requester.fetch(nil)

                  expect(result.success?).to be true
                  expect(change_keys(result)).to eq ["flagkey"]
                end
              ensure
                ENV["http_proxy"] = nil
              end
            end
          end
        end
      end

      RSpec.describe HTTPPollingRequester do
        let(:selector) { Interfaces::DataSystem::Selector.new(state: "(p:id:5)", version: 5) }

        def fetch_with(selector)
          with_server do |server|
            server.setup_ok_response("/", PollingHTTPRequesterSpec.fdv2_payload("flagkey", 1))
            requester = HTTPPollingRequester.new(
              PollingHTTPRequesterSpec::SDK_KEY,
              HttpConfigOptions.new(base_uri: server.base_uri.to_s),
              Config.new(logger: $null_log)
            )
            begin
              requester.fetch(selector)
            ensure
              requester.stop
            end
            expect(server.requests.count).to eq 1
            yield server.requests[0]
          end
        end

        it "sends the basis query parameter when the selector is defined" do
          fetch_with(selector) do |request|
            expect(request.path).to eq FDV2_POLLING_ENDPOINT
            expect(request.query).to eq({ "basis" => "(p:id:5)" })
          end
        end

        it "does not send the basis query parameter when the selector is not defined" do
          fetch_with(Interfaces::DataSystem::Selector.no_selector) do |request|
            expect(request.unparsed_uri).to eq FDV2_POLLING_ENDPOINT
          end
        end

        it "does not send the basis query parameter when there is no selector" do
          fetch_with(nil) do |request|
            expect(request.unparsed_uri).to eq FDV2_POLLING_ENDPOINT
          end
        end
      end

      RSpec.describe HTTPFDv1PollingRequester do
        it "does not send the basis query parameter when the selector is defined" do
          with_server do |server|
            server.setup_ok_response("/", PollingHTTPRequesterSpec.fdv1_payload("flagkey", 1))
            requester = HTTPFDv1PollingRequester.new(
              PollingHTTPRequesterSpec::SDK_KEY,
              HttpConfigOptions.new(base_uri: server.base_uri.to_s),
              Config.new(logger: $null_log)
            )
            begin
              requester.fetch(Interfaces::DataSystem::Selector.new(state: "(p:id:5)", version: 5))
            ensure
              requester.stop
            end

            expect(server.requests.count).to eq 1
            expect(server.requests[0].unparsed_uri).to eq FDV1_POLLING_ENDPOINT
          end
        end
      end
    end
  end
end
