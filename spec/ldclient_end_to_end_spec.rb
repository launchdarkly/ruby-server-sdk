require "http_util"
require "spec_helper"


SDK_KEY = "sdk-key"

USER = { key: 'userkey' }

ALWAYS_TRUE_FLAG = { key: 'flagkey', version: 1, on: false, offVariation: 1, variations: [ false, true ] }
DATA_WITH_ALWAYS_TRUE_FLAG = {
  flags: { ALWAYS_TRUE_FLAG[:key  ].to_sym => ALWAYS_TRUE_FLAG },
  segments: {}
}
PUT_EVENT_WITH_ALWAYS_TRUE_FLAG = "event: put\ndata:{\"data\":#{DATA_WITH_ALWAYS_TRUE_FLAG.to_json}}\n\n'"

def with_client(config)
  client = LaunchDarkly::LDClient.new(SDK_KEY, config)
  begin
    yield client
  ensure
    client.close
  end
end

module LaunchDarkly
  # Note that we can't do end-to-end tests in streaming mode until we have a test server that can do streaming
  # responses, which is difficult in WEBrick.

  describe "LDClient end-to-end" do
    it "starts in polling mode" do
      with_server do |poll_server|
        poll_server.setup_ok_response("/sdk/latest-all", DATA_WITH_ALWAYS_TRUE_FLAG.to_json, "application/json")
        
        config = Config.new(
          stream: false,
          base_uri: poll_server.base_uri.to_s,
          send_events: false,
          logger: NullLogger.new
        )
        with_client(config) do |client|
          expect(client.initialized?).to be true
          expect(client.variation(ALWAYS_TRUE_FLAG[:key], USER, false)).to be true
        end
      end
    end

    it "fails in polling mode with 401 error" do
      with_server do |poll_server|
        poll_server.setup_status_response("/sdk/latest-all", 401)
        
        config = Config.new(
          stream: false,
          base_uri: poll_server.base_uri.to_s,
          send_events: false,
          logger: NullLogger.new
        )
        with_client(config) do |client|
          expect(client.initialized?).to be false
          expect(client.variation(ALWAYS_TRUE_FLAG[:key], USER, false)).to be false
        end
      end
    end

    it "sends event without diagnostics" do
      with_server do |poll_server|
        with_server do |events_server|
          events_server.setup_ok_response("/bulk", "")
          poll_server.setup_ok_response("/sdk/latest-all", '{"flags":{},"segments":{}}', "application/json")
          
          config = Config.new(
            stream: false,
            base_uri: poll_server.base_uri.to_s,
            events_uri: events_server.base_uri.to_s,
            diagnostic_opt_out: true,
            logger: NullLogger.new
          )
          with_client(config) do |client|
            client.identify(USER)
            client.flush

            req, body = events_server.await_request_with_body
            expect(req.header['authorization']).to eq [ SDK_KEY ]
            expect(req.header['connection']).to eq [ "Keep-Alive" ]
            data = JSON.parse(body)
            expect(data.length).to eq 1
            expect(data[0]["kind"]).to eq "identify"
          end
        end
      end
    end

    it "sends diagnostic event" do
      with_server do |poll_server|
        with_server do |events_server|
          events_server.setup_ok_response("/bulk", "")
          events_server.setup_ok_response("/diagnostic", "")
          poll_server.setup_ok_response("/sdk/latest-all", '{"flags":{},"segments":{}}', "application/json")
          
          config = Config.new(
            stream: false,
            base_uri: poll_server.base_uri.to_s,
            events_uri: events_server.base_uri.to_s,
            logger: NullLogger.new
          )
          with_client(config) do |client|
            user = { key: 'userkey' }
            client.identify(user)
            client.flush

            req0, body0 = events_server.await_request_with_body
            req1, body1 = events_server.await_request_with_body
            req = req0.path == "/diagnostic" ? req0 : req1
            body = req0.path == "/diagnostic" ? body0 : body1
            expect(req.header['authorization']).to eq [ SDK_KEY ]
            expect(req.header['connection']).to eq [ "Keep-Alive" ]
            data = JSON.parse(body)
            expect(data["kind"]).to eq "diagnostic-init"
          end
        end
      end
    end

    it "can use socket factory" do
      with_server do |poll_server|
        with_server do |events_server|
          events_server.setup_ok_response("/bulk", "")
          poll_server.setup_ok_response("/sdk/latest-all", '{"flags":{},"segments":{}}', "application/json")
          
          config = Config.new(
            stream: false,
            base_uri: "http://polling.com",
            events_uri: "http://events.com",
            diagnostic_opt_out: true,
            logger: NullLogger.new,
            socket_factory: SocketFactoryFromHash.new({
              "polling.com" => poll_server.port,
              "events.com" => events_server.port  
            })
          )
          with_client(config) do |client|
            client.identify(USER)
            client.flush

            req, body = events_server.await_request_with_body
            expect(req.header['authorization']).to eq [ SDK_KEY ]
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
