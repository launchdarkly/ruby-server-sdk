require "http_util"
require "mock_components"
require "spec_helper"


ALWAYS_TRUE_FLAG = { key: 'flagkey', version: 1, on: false, offVariation: 1, variations: [ false, true ] }
DATA_WITH_ALWAYS_TRUE_FLAG = {
  flags: { ALWAYS_TRUE_FLAG[:key ].to_sym => ALWAYS_TRUE_FLAG },
  segments: {},
}
PUT_EVENT_WITH_ALWAYS_TRUE_FLAG = "event: put\ndata:{\"data\":#{DATA_WITH_ALWAYS_TRUE_FLAG.to_json}}\n\n'"

module LaunchDarkly
  # Note that we can't do end-to-end tests in streaming mode until we have a test server that can do streaming
  # responses, which is difficult in WEBrick.

  describe "LDClient end-to-end" do
    it "starts in polling mode" do
      with_server do |poll_server|
        poll_server.setup_ok_response("/sdk/latest-all", DATA_WITH_ALWAYS_TRUE_FLAG.to_json, "application/json")

        with_client(test_config(stream: false, data_source: nil, base_uri: poll_server.base_uri.to_s)) do |client|
          expect(client.initialized?).to be true
          expect(client.variation(ALWAYS_TRUE_FLAG[:key], basic_context, false)).to be true
        end
      end
    end

    it "fails in polling mode with 401 error" do
      with_server do |poll_server|
        poll_server.setup_status_response("/sdk/latest-all", 401)

        with_client(test_config(stream: false, data_source: nil, base_uri: poll_server.base_uri.to_s)) do |client|
          expect(client.initialized?).to be false
          expect(client.variation(ALWAYS_TRUE_FLAG[:key], basic_context, false)).to be false
        end
      end
    end

    it "sends event without diagnostics" do
      with_server do |events_server|
        events_server.setup_ok_response("/bulk", "")

        config = test_config(
          send_events: true,
          events_uri: events_server.base_uri.to_s,
          diagnostic_opt_out: true
        )
        with_client(config) do |client|
          client.identify(basic_context)
          client.flush

          req, body = events_server.await_request_with_body
          expect(req.header['authorization']).to eq [ sdk_key ]
          expect(req.header['connection']).to eq [ "Keep-Alive" ]
          data = JSON.parse(body)
          expect(data.length).to eq 1
          expect(data[0]["kind"]).to eq "identify"
        end
      end
    end

    it "sends diagnostic event" do
      with_server do |events_server|
        events_server.setup_ok_response("/bulk", "")
        events_server.setup_ok_response("/diagnostic", "")

        config = test_config(
          send_events: true,
          events_uri: events_server.base_uri.to_s
        )
        with_client(config) do |client|
          client.identify(basic_context)
          client.flush

          req0, body0 = events_server.await_request_with_body
          req1, body1 = events_server.await_request_with_body
          req = req0.path == "/diagnostic" ? req0 : req1
          body = req0.path == "/diagnostic" ? body0 : body1
          expect(req.header['authorization']).to eq [ sdk_key ]
          expect(req.header['connection']).to eq [ "Keep-Alive" ]
          data = JSON.parse(body)
          expect(data["kind"]).to eq "diagnostic-init"
        end
      end
    end

    it "can use socket factory" do
      with_server do |poll_server|
        with_server do |events_server|
          events_server.setup_ok_response("/bulk", "")
          poll_server.setup_ok_response("/sdk/latest-all", '{"flags":{},"segments":{}}', "application/json")

          config = test_config(
            stream: false,
            data_source: nil,
            send_events: true,
            base_uri: "http://fake-polling-server",
            events_uri: "http://fake-events-server",
            diagnostic_opt_out: true,
            socket_factory: SocketFactoryFromHash.new({
              "fake-polling-server" => poll_server.port,
              "fake-events-server" => events_server.port,
            })
          )
          with_client(config) do |client|
            client.identify(basic_context)
            client.flush

            req, body = events_server.await_request_with_body
            expect(req.header['authorization']).to eq [ sdk_key ]
            expect(req.header['connection']).to eq [ "Keep-Alive" ]
            data = JSON.parse(body)
            expect(data.length).to eq 1
            expect(data[0]["kind"]).to eq "identify"
          end
        end
      end
    end

    # TODO: TLS tests with self-signed cert
  end
end
