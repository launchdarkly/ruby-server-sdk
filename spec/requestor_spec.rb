require "http_util"
require "spec_helper"

describe LaunchDarkly::Requestor do
  describe ".request_all_flags" do
    describe "with a proxy" do
      it "converts the proxy option" do
        content = '{"flags": {"flagkey": {"key": "flagkey"}}}'
        with_server do |server|
          server.setup_ok_response("/sdk/latest-all", content, "application/json", { "etag" => "x" })
          with_server(StubProxyServer.new) do |proxy|
            config = LaunchDarkly::Config.new(base_uri: server.base_uri.to_s, proxy: proxy.base_uri.to_s)
            r = LaunchDarkly::Requestor.new("sdk-key", config)
            result = r.request_all_data
            expect(result).to eq(JSON.parse(content, symbolize_names: true))
          end
        end
      end
    end
    describe "without a proxy" do
      it "sends headers" do
        content = '{"flags": {}}'
        sdk_key = 'sdk-key'
        with_server do |server|
          server.setup_ok_response("/sdk/latest-all", content, "application/json", { "etag" => "x" })
          r = LaunchDarkly::Requestor.new(sdk_key, LaunchDarkly::Config.new({ base_uri: server.base_uri.to_s }))
          r.request_all_data
          expect(server.requests.length).to eq 1
          req = server.requests[0]
          expect(req.header['authorization']).to eq [sdk_key]
          expect(req.header['user-agent']).to eq ["RubyClient/" + LaunchDarkly::VERSION]
        end
      end

      it "receives data" do
        content = '{"flags": {"flagkey": {"key": "flagkey"}}}'
        with_server do |server|
          server.setup_ok_response("/sdk/latest-all", content, "application/json", { "etag" => "x" })
          r = LaunchDarkly::Requestor.new("sdk-key", LaunchDarkly::Config.new({ base_uri: server.base_uri.to_s }))
          result = r.request_all_data
          expect(result).to eq(JSON.parse(content, symbolize_names: true))
        end
      end

      it "handles Unicode content" do
        content = '{"flags": {"flagkey": {"key": "flagkey", "variations": ["blue", "grėeń"]}}}'
        with_server do |server|
          server.setup_ok_response("/sdk/latest-all", content, "application/json", { "etag" => "x" })
          # Note that the ETag header here is important because without it, the HTTP cache will not be used,
          # and the cache is what required a fix to handle Unicode properly. See:
          #   https://github.com/launchdarkly/ruby-client/issues/90
          r = LaunchDarkly::Requestor.new("sdk-key", LaunchDarkly::Config.new({ base_uri: server.base_uri.to_s }))
          result = r.request_all_data
          expect(result).to eq(JSON.parse(content, symbolize_names: true))
        end
      end
    end
  end
end
