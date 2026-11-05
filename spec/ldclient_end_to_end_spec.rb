require "http_util"
require "mock_components"
require "spec_helper"


ALWAYS_TRUE_FLAG = { key: 'flagkey', version: 1, on: false, offVariation: 1, variations: [ false, true ] }
FLAGS_WITH_ALWAYS_TRUE_FLAG = { ALWAYS_TRUE_FLAG[:key].to_sym => ALWAYS_TRUE_FLAG }

module LaunchDarkly
  # Note that we can't do end-to-end tests in streaming mode until we have a test server that can do streaming
  # responses, which is difficult in WEBrick.

  describe "LDClient end-to-end", flaky: true do
    it "starts in polling mode" do
      with_server do |poll_server|
        poll_server.setup_ok_response("/sdk/poll", fdv2_poll_payload(flags: FLAGS_WITH_ALWAYS_TRUE_FLAG), "application/json")

        with_client(test_config(data_system_config: polling_data_system_builder(poll_server.base_uri.to_s).build)) do |client|
          expect(client.initialized?).to be true
          expect(client.variation(ALWAYS_TRUE_FLAG[:key], basic_context, false)).to be true
        end
      end
    end

    it "stops without waiting the full start time and turns off in polling mode with 401 error" do
      with_server do |poll_server|
        poll_server.setup_status_response("/sdk/poll", 401)

        config = test_config(data_system_config: polling_data_system_builder(poll_server.base_uri.to_s).build)
        started_at = Time.now
        ensure_close(LDClient.new(sdk_key, config, 5)) do |client|
          expect(Time.now - started_at).to be < 5
          expect(client.initialized?).to be false
          status = client.data_source_status_provider.status
          expect(status.state).to eq(Interfaces::DataSource::Status::OFF)
          expect(status.last_error.status_code).to eq(401)
          expect(poll_server.requests.count).to eq(1)
          expect(client.variation(ALWAYS_TRUE_FLAG[:key], basic_context, false)).to be false
        end
      end
    end

    it "stops without waiting the full start time and turns off in streaming mode with 401 error" do
      with_server do |stream_server|
        stream_server.setup_status_response("/sdk/stream", 401)

        data_system = DataSystem.custom
          .synchronizers([DataSystem.streaming_ds_builder.base_uri(stream_server.base_uri.to_s)])
          .build
        # The SSE worker thread can log after the example ends, so the logger cannot be a test double.
        config = test_config(data_system_config: data_system, logger: $null_log)
        started_at = Time.now
        ensure_close(LDClient.new(sdk_key, config, 5)) do |client|
          expect(Time.now - started_at).to be < 5
          expect(client.initialized?).to be false
          status = client.data_source_status_provider.status
          expect(status.state).to eq(Interfaces::DataSource::Status::OFF)
          expect(status.last_error.status_code).to eq(401)
          expect(stream_server.requests.count).to eq(1)
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
          poll_server.setup_ok_response("/sdk/poll", fdv2_poll_payload, "application/json")

          socket_factory = SocketFactoryFromHash.new({
            "fake-polling-server" => poll_server.port,
            "fake-events-server" => events_server.port,
          })
          polling = DataSystem.polling_ds_builder.base_uri("http://fake-polling-server").socket_factory(socket_factory)
          config = test_config(
            data_system_config: DataSystem.custom.synchronizers([polling]).build,
            send_events: true,
            events_uri: "http://fake-events-server",
            diagnostic_opt_out: true,
            socket_factory: socket_factory
          )
          with_client(config) do |client|
            expect(client.initialized?).to be true
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
