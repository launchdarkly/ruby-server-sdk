require "http_util"
require "model_builders"
require "spec_helper"

$sdk_key = "secret"

describe LaunchDarkly::Requestor do
  def with_requestor(base_uri, opts = {})
    r = LaunchDarkly::Requestor.new($sdk_key, LaunchDarkly::Config.new({ base_uri: base_uri, application: {id: "id", version: "version"} }.merge(opts)))
    begin
      yield r
    ensure
      r.stop
    end
  end

  describe "request_all_flags" do
    it "uses expected URI and headers" do
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_ok_response("/", "{}")
          requestor.request_all_data()
          expect(server.requests.count).to eq 1
          expect(server.requests[0].unparsed_uri).to eq "/sdk/latest-all"
          expect(server.requests[0].header).to include({
            "authorization" => [ $sdk_key ],
            "user-agent" => [ "RubyClient/" + LaunchDarkly::VERSION ],
            "x-launchdarkly-tags" => [ "application-id/id application-version/version" ],
          })
        end
      end
    end

    it "parses response" do
      expected_data = DataSetBuilder.new.flag(FlagBuilder.new("x").build)
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_ok_response("/", expected_data.to_json)
          data = requestor.request_all_data()
          expect(data).to eq expected_data.to_store_data
        end
      end
    end

    it "logs debug output" do
      logger = ::Logger.new($stdout)
      logger.level = ::Logger::DEBUG
      with_server do |server|
        with_requestor(server.base_uri.to_s, { logger: logger }) do |requestor|
          server.setup_ok_response("/", FlagBuilder.new("x").build.to_json)
          expect do
            requestor.request_all_data()
          end.to output(/\[LDClient\] Got response from uri:/).to_stdout_from_any_process
        end
      end
    end

    it "sends etag from previous response" do
      etag = "xyz"
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_response("/") do |req, res|
            res.status = 200
            res.body = "{}"
            res["ETag"] = etag
          end
          requestor.request_all_data()
          expect(server.requests.count).to eq 1

          requestor.request_all_data()
          expect(server.requests.count).to eq 2
          expect(server.requests[1].header).to include({ "if-none-match" => [ etag ] })
        end
      end
    end

    it "sends wrapper header if configured" do
      with_server do |server|
        with_requestor(server.base_uri.to_s, { wrapper_name: 'MyWrapper', wrapper_version: '1.0' }) do |requestor|
          server.setup_ok_response("/", "{}")
          requestor.request_all_data()
          expect(server.requests.count).to eq 1
          expect(server.requests[0].header).to include({
            "x-launchdarkly-wrapper" => [ "MyWrapper/1.0" ],
          })
        end
      end
    end

    it "can reuse cached data" do
      etag = "xyz"
      expected_data = DataSetBuilder.new.flag(FlagBuilder.new("x").build)
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_response("/") do |req, res|
            res.status = 200
            res.body = expected_data.to_json
            res["ETag"] = etag
          end
          requestor.request_all_data()
          expect(server.requests.count).to eq 1

          server.setup_response("/") do |req, res|
            res.status = 304
          end
          data = requestor.request_all_data()
          expect(server.requests.count).to eq 2
          expect(server.requests[1].header).to include({ "if-none-match" => [ etag ] })
          expect(data).to eq expected_data.to_store_data
        end
      end
    end

    it "replaces cached data with new data" do
      etag1 = "abc"
      etag2 = "xyz"
      expected_data1 = DataSetBuilder.new.flag(FlagBuilder.new("x").build)
      expected_data2 = DataSetBuilder.new.flag(FlagBuilder.new("y").build)
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_response("/") do |req, res|
            res.status = 200
            res.body = expected_data1.to_json
            res["ETag"] = etag1
          end
          data = requestor.request_all_data()
          expect(data).to eq expected_data1.to_store_data
          expect(server.requests.count).to eq 1

          server.setup_response("/") do |req, res|
            res.status = 304
          end
          data = requestor.request_all_data()
          expect(data).to eq expected_data1.to_store_data
          expect(server.requests.count).to eq 2
          expect(server.requests[1].header).to include({ "if-none-match" => [ etag1 ] })

          server.setup_response("/") do |req, res|
            res.status = 200
            res.body = expected_data2.to_json
            res["ETag"] = etag2
          end
          data = requestor.request_all_data()
          expect(data).to eq expected_data2.to_store_data
          expect(server.requests.count).to eq 3
          expect(server.requests[2].header).to include({ "if-none-match" => [ etag1 ] })

          server.setup_response("/") do |req, res|
            res.status = 304
          end
          data = requestor.request_all_data()
          expect(data).to eq expected_data2.to_store_data
          expect(server.requests.count).to eq 4
          expect(server.requests[3].header).to include({ "if-none-match" => [ etag2 ] })
        end
      end
    end

    it "uses UTF-8 encoding by default" do
      expected_data = DataSetBuilder.new.flag(FlagBuilder.new("flagkey").variations("blue", "grėeń").build)
      with_server do |server|
        server.setup_ok_response("/sdk/latest-all", expected_data.to_json, "application/json")
        with_requestor(server.base_uri.to_s) do |requestor|
          data = requestor.request_all_data
          expect(data).to eq expected_data.to_store_data
        end
      end
    end

    it "detects other encodings from Content-Type" do
      expected_data = DataSetBuilder.new.flag(FlagBuilder.new("flagkey").variations("proszę", "dziękuję").build)
      with_server do |server|
        server.setup_ok_response("/sdk/latest-all", expected_data.to_json.encode(Encoding::ISO_8859_2),
          "text/plain; charset=ISO-8859-2")
        with_requestor(server.base_uri.to_s) do |requestor|
          data = requestor.request_all_data
          expect(data).to eq expected_data.to_store_data
        end
      end
    end

    it "throws exception for error status" do
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_response("/") do |req, res|
            res.status = 400
          end
          expect { requestor.request_all_data() }.to raise_error(LaunchDarkly::UnexpectedResponseError)
        end
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
      expected_data = DataSetBuilder.new.flag(FlagBuilder.new("x").build)
      with_server do |proxy|
        proxy.setup_ok_response("/sdk/latest-all", expected_data.to_json, "application/json", { "etag" => "x" })
        begin
          ENV["http_proxy"] = proxy.base_uri.to_s
          with_requestor(fake_target_uri) do |requestor|
            data = requestor.request_all_data
            expect(data).to eq expected_data.to_store_data
          end
        ensure
          ENV["http_proxy"] = nil
        end
      end
    end
  end
end
