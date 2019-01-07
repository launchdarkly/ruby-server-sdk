require "spec_helper"
require "http_util"

$sdk_key = "secret"

describe LaunchDarkly::Requestor do
  def with_requestor(base_uri)
    r = LaunchDarkly::Requestor.new($sdk_key, LaunchDarkly::Config.new(base_uri: base_uri))
    yield r
    r.stop
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
            "user-agent" => [ "RubyClient/" + LaunchDarkly::VERSION ]
          })
        end
      end
    end

    it "parses response" do
      expected_data = { flags: { x: { key: "x" } } }
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_ok_response("/", expected_data.to_json)
          data = requestor.request_all_data()
          expect(data).to eq expected_data
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

    it "can reuse cached data" do
      etag = "xyz"
      expected_data = { flags: { x: { key: "x" } } }
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
          expect(data).to eq expected_data
        end
      end
    end

    it "replaces cached data with new data" do
      etag1 = "abc"
      etag2 = "xyz"
      expected_data1 = { flags: { x: { key: "x" } } }
      expected_data2 = { flags: { y: { key: "y" } } }
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_response("/") do |req, res|
            res.status = 200
            res.body = expected_data1.to_json
            res["ETag"] = etag1
          end
          data = requestor.request_all_data()
          expect(data).to eq expected_data1
          expect(server.requests.count).to eq 1

          server.setup_response("/") do |req, res|
            res.status = 304
          end
          data = requestor.request_all_data()
          expect(data).to eq expected_data1
          expect(server.requests.count).to eq 2
          expect(server.requests[1].header).to include({ "if-none-match" => [ etag1 ] })

          server.setup_response("/") do |req, res|
            res.status = 200
            res.body = expected_data2.to_json
            res["ETag"] = etag2
          end
          data = requestor.request_all_data()
          expect(data).to eq expected_data2
          expect(server.requests.count).to eq 3
          expect(server.requests[2].header).to include({ "if-none-match" => [ etag1 ] })

          server.setup_response("/") do |req, res|
            res.status = 304
          end
          data = requestor.request_all_data()
          expect(data).to eq expected_data2
          expect(server.requests.count).to eq 4
          expect(server.requests[3].header).to include({ "if-none-match" => [ etag2 ] })
        end
      end
    end

    it "uses UTF-8 encoding by default" do
      content = '{"flags": {"flagkey": {"key": "flagkey", "variations": ["blue", "grėeń"]}}}'
      with_server do |server|
        server.setup_ok_response("/sdk/latest-all", content, "application/json")
        with_requestor(server.base_uri.to_s) do |requestor|
          data = requestor.request_all_data
          expect(data).to eq(JSON.parse(content, symbolize_names: true))
        end
      end
    end

    it "detects other encodings from Content-Type" do
      content = '{"flags": {"flagkey": {"key": "flagkey", "variations": ["proszę", "dziękuję"]}}}'
      with_server do |server|
        server.setup_ok_response("/sdk/latest-all", content.encode(Encoding::ISO_8859_2),
          "text/plain; charset=ISO-8859-2")
        with_requestor(server.base_uri.to_s) do |requestor|
          data = requestor.request_all_data
          expect(data).to eq(JSON.parse(content, symbolize_names: true))
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
  end

  describe "request_flag" do
    it "uses expected URI and headers" do
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_ok_response("/", "{}")
          requestor.request_flag("key")
          expect(server.requests.count).to eq 1
          expect(server.requests[0].unparsed_uri).to eq "/sdk/latest-flags/key"
          expect(server.requests[0].header).to include({
            "authorization" => [ $sdk_key ],
            "user-agent" => [ "RubyClient/" + LaunchDarkly::VERSION ]
          })
        end
      end
    end
  end

  describe "request_segment" do
    it "uses expected URI and headers" do
      with_server do |server|
        with_requestor(server.base_uri.to_s) do |requestor|
          server.setup_ok_response("/", "{}")
          requestor.request_segment("key")
          expect(server.requests.count).to eq 1
          expect(server.requests[0].unparsed_uri).to eq "/sdk/latest-segments/key"
          expect(server.requests[0].header).to include({
            "authorization" => [ $sdk_key ],
            "user-agent" => [ "RubyClient/" + LaunchDarkly::VERSION ]
          })
        end
      end
    end
  end
end
