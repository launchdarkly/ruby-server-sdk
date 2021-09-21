require "ldclient-rb/impl/event_sender"

require "http_util"
require "spec_helper"

require "time"

module LaunchDarkly
  module Impl
    describe EventSender do
      subject { EventSender }

      let(:sdk_key) { "sdk_key" }
      let(:fake_data) { '{"things":[]}' }

      def make_sender(server)
        subject.new(sdk_key, Config.new(events_uri: server.base_uri.to_s, logger: $null_log), nil, 0.1)
      end

      def with_sender_and_server
        with_server do |server|
          yield make_sender(server), server
        end
      end

      it "sends analytics event data" do
        with_sender_and_server do |es, server|
          server.setup_ok_response("/bulk", "")

          result = es.send_event_data(fake_data, "", false)

          expect(result.success).to be true
          expect(result.must_shutdown).to be false
          expect(result.time_from_server).not_to be_nil

          req = server.await_request
          expect(req.body).to eq fake_data
          expect(req.header).to include({
            "authorization" => [ sdk_key ],
            "content-type" => [ "application/json" ],
            "user-agent" => [ "RubyClient/" + LaunchDarkly::VERSION ],
            "x-launchdarkly-event-schema" => [ "3" ],
            "connection" => [ "Keep-Alive" ]
          })
          expect(req.header['x-launchdarkly-payload-id']).not_to eq []
        end
      end

      it "can use a socket factory" do
        with_server do |server|
          server.setup_ok_response("/bulk", "")

          config = Config.new(events_uri: "http://fake-event-server/bulk",
            socket_factory: SocketFactoryFromHash.new({"fake-event-server" => server.port}),
            logger: $null_log)
          es = subject.new(sdk_key, config, nil, 0.1)

          result = es.send_event_data(fake_data, "", false)

          expect(result.success).to be true
          req = server.await_request
          expect(req.body).to eq fake_data
          expect(req.host).to eq "fake-event-server"
        end
      end

      it "generates a new payload ID for each payload" do
        with_sender_and_server do |es, server|
          server.setup_ok_response("/bulk", "")

          result1 = es.send_event_data(fake_data, "", false)
          result2 = es.send_event_data(fake_data, "", false)
          expect(result1.success).to be true
          expect(result2.success).to be true

          req1, body1 = server.await_request_with_body
          req2, body2 = server.await_request_with_body
          expect(body1).to eq fake_data
          expect(body2).to eq fake_data
          expect(req1.header['x-launchdarkly-payload-id']).not_to eq req2.header['x-launchdarkly-payload-id']
        end
      end

      it "sends diagnostic event data" do
        with_sender_and_server do |es, server|
          server.setup_ok_response("/diagnostic", "")

          result = es.send_event_data(fake_data, "", true)

          expect(result.success).to be true
          expect(result.must_shutdown).to be false
          expect(result.time_from_server).not_to be_nil

          req, body = server.await_request_with_body
          expect(body).to eq fake_data
          expect(req.header).to include({
            "authorization" => [ sdk_key ],
            "content-type" => [ "application/json" ],
            "user-agent" => [ "RubyClient/" + LaunchDarkly::VERSION ],
            "connection" => [ "Keep-Alive" ]
          })
          expect(req.header['x-launchdarkly-event-schema']).to eq []
          expect(req.header['x-launchdarkly-payload-id']).to eq []
        end
      end

      it "can use a proxy server" do
        with_server do |server|
          server.setup_ok_response("/bulk", "")
    
          with_server(StubProxyServer.new) do |proxy|
            begin
              ENV["http_proxy"] = proxy.base_uri.to_s

              es = make_sender(server)

              result = es.send_event_data(fake_data, "", false)
              
              expect(result.success).to be true

              req, body = server.await_request_with_body
              expect(body).to eq fake_data
            ensure
              ENV["http_proxy"] = nil
            end
          end
        end
      end
    
      [400, 408, 429, 500].each do |status|
        it "handles recoverable error #{status}" do
          with_sender_and_server do |es, server|
            req_count = 0
            server.setup_response("/bulk") do |req, res|
              req_count = req_count + 1
              res.status = req_count == 2 ? 200 : status
            end

            result = es.send_event_data(fake_data, "", false)

            expect(result.success).to be true
            expect(result.must_shutdown).to be false
            expect(result.time_from_server).not_to be_nil

            expect(server.requests.count).to eq 2
            req1, body1 = server.await_request_with_body
            req2, body2 = server.await_request_with_body
            expect(body1).to eq fake_data
            expect(body2).to eq fake_data
            expect(req1.header['x-launchdarkly-payload-id']).to eq req2.header['x-launchdarkly-payload-id']
          end
        end
      end

      [400, 408, 429, 500].each do |status|
        it "only retries error #{status} once" do
          with_sender_and_server do |es, server|
            req_count = 0
            server.setup_response("/bulk") do |req, res|
              req_count = req_count + 1
              res.status = req_count == 3 ? 200 : status
            end

            result = es.send_event_data(fake_data, "", false)

            expect(result.success).to be false
            expect(result.must_shutdown).to be false
            expect(result.time_from_server).to be_nil

            expect(server.requests.count).to eq 2
            req1, body1 = server.await_request_with_body
            req2, body2 = server.await_request_with_body
            expect(body1).to eq fake_data
            expect(body2).to eq fake_data
            expect(req1.header['x-launchdarkly-payload-id']).to eq req2.header['x-launchdarkly-payload-id']
          end
        end
      end

      [401, 403].each do |status|
        it "gives up after unrecoverable error #{status}" do
          with_sender_and_server do |es, server|
            server.setup_response("/bulk") do |req, res|
              res.status = status
            end

            result = es.send_event_data(fake_data, "", false)

            expect(result.success).to be false
            expect(result.must_shutdown).to be true
            expect(result.time_from_server).to be_nil

            expect(server.requests.count).to eq 1
          end
        end
      end
    end
  end
end
