require "ldclient-rb/impl/event_sender"

require "http_util"
require "spec_helper"

require "time"

module LaunchDarkly
  module Impl
    describe EventSender, flaky: true do
      subject { EventSender }

      let(:sdk_key) { "sdk_key" }
      let(:fake_data) { '{"things":[],"stuff":false,"other examples":["you", "me", "us", "we"]}' }

      def make_sender(config_options = {})
        config_options = {logger: $null_log}.merge(config_options)
        subject.new(sdk_key, Config.new(config_options), nil, 0.1)
      end

      def with_sender_and_server(config_options = {})
        enable_compression = config_options[:compress_events] || false
        with_server(enable_compression: enable_compression) do |server|
          config_options[:events_uri] = server.base_uri.to_s
          yield make_sender(config_options), server
        end
      end

      it "sends analytics event data without compression enabled" do
        with_sender_and_server(compress_events: false) do |es, server|
          server.setup_ok_response("/bulk", "")

          result = es.send_event_data(fake_data, "", false)

          expect(result.success).to be true
          expect(result.must_shutdown).to be false
          expect(result.time_from_server).not_to be_nil

          req, body = server.await_request_with_body
          expect(body).to eq fake_data
          expect(req.header).to include({
            "authorization" => [ sdk_key ],
            "content-type" => [ "application/json" ],
            "user-agent" => [ "RubyClient/" + LaunchDarkly::VERSION ],
            "x-launchdarkly-event-schema" => [ "4" ],
            "connection" => [ "Keep-Alive" ],
          })
          expect(req.header['x-launchdarkly-payload-id']).not_to eq []
          expect(req.header['content-encoding']).to eq []
          expect(req.header['content-length'][0].to_i).to eq fake_data.length
        end
      end

      it "sends analytics event data with compression enabled" do
        with_sender_and_server(compress_events: true) do |es, server|
          server.setup_ok_response("/bulk", "")

          result = es.send_event_data(fake_data, "", false)

          expect(result.success).to be true
          expect(result.must_shutdown).to be false
          expect(result.time_from_server).not_to be_nil

          req, body = server.await_request_with_body
          expect(body).to eq fake_data
          expect(req.header).to include({
            "authorization" => [ sdk_key ],
            "content-encoding" => [ "gzip" ],
            "content-type" => [ "application/json" ],
            "user-agent" => [ "RubyClient/" + LaunchDarkly::VERSION ],
            "x-launchdarkly-event-schema" => [ "4" ],
            "connection" => [ "Keep-Alive" ],
          })
          expect(req.header['x-launchdarkly-payload-id']).not_to eq []
          expect(req.header['content-length'][0].to_i).to be > fake_data.length
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
          req, body = server.await_request_with_body
          expect(body).to eq fake_data
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
            "connection" => [ "Keep-Alive" ],
          })
          expect(req.header['x-launchdarkly-event-schema']).to eq []
          expect(req.header['x-launchdarkly-payload-id']).to eq []
        end
      end

      it "can use a proxy server" do
        fake_target_uri = "http://request-will-not-really-go-here"
        # Instead of a real proxy server, we just create a basic test HTTP server that
        # pretends to be a proxy. The proof that the proxy logic is working correctly is
        # that the request goes to that server, instead of to fake_target_uri. We can't
        # use a real proxy that really forwards requests to another test server, because
        # that test server would be at localhost, and proxy environment variables are
        # ignored if the target is localhost.
        with_server do |proxy|
          proxy.setup_ok_response("/bulk", "")

          begin
            ENV["http_proxy"] = proxy.base_uri.to_s

            es = make_sender(events_uri: fake_target_uri)

            result = es.send_event_data(fake_data, "", false)

            expect(result.success).to be true
          ensure
            ENV["http_proxy"] = nil
          end

          _, body = proxy.await_request_with_body
          expect(body).to eq fake_data
        end
      end

      [400, 408, 429, 500].each do |status|
        it "handles recoverable error #{status}" do
          with_sender_and_server do |es, server|
            req_count = 0
            server.setup_response("/bulk") do |_, res|
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
            server.setup_response("/bulk") do |_, res|
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
            server.setup_response("/bulk") do |_, res|
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
