require "spec_helper"
require "faraday"

describe LaunchDarkly::Requestor do
  describe ".request_all_flags" do
    describe "with a proxy" do
      let(:requestor) {
        LaunchDarkly::Requestor.new(
          "key",
          LaunchDarkly::Config.new({
<<<<<<< HEAD
            proxy: "http://proxy.com",
            base_uri: "http://ld.com"
=======
            :proxy => "http://proxy.com",
            :base_uri => "http://ld.com"
>>>>>>> ba355ed1fc08c6162e2335f60480c0d658b04964
          })
        )
      }
      it "converts the proxy option" do
        faraday = Faraday.new
        requestor.instance_variable_set(:@client, faraday)
        allow(faraday).to receive(:get) do |*args, &block|
<<<<<<< HEAD
          req = double(Faraday::Request, headers: {}, options: Faraday::RequestOptions.new)
=======
          req = double(Faraday::Request, :headers => {}, :options => Faraday::RequestOptions.new)
>>>>>>> ba355ed1fc08c6162e2335f60480c0d658b04964
          block.call(req)
          expect(args).to eq ['http://ld.com/sdk/latest-flags']
          expect(req.options.proxy[:uri]).to eq URI("http://proxy.com")
          double(body: '{"foo": "bar"}', status: 200, headers: {})
        end

        requestor.request_all_flags()
      end
    end
    describe "without a proxy" do
      let(:requestor) {
        LaunchDarkly::Requestor.new(
          "key",
          LaunchDarkly::Config.new({
<<<<<<< HEAD
            base_uri: "http://ld.com"
=======
            :base_uri => "http://ld.com"
>>>>>>> ba355ed1fc08c6162e2335f60480c0d658b04964
          })
        )
      }
      it "converts the proxy option" do
        faraday = Faraday.new
        requestor.instance_variable_set(:@client, faraday)
        allow(faraday).to receive(:get) do |*args, &block|
<<<<<<< HEAD
          req = double(Faraday::Request, headers: {}, options: Faraday::RequestOptions.new)
=======
          req = double(Faraday::Request, :headers => {}, :options => Faraday::RequestOptions.new)
>>>>>>> ba355ed1fc08c6162e2335f60480c0d658b04964
          block.call(req)
          expect(args).to eq ['http://ld.com/sdk/latest-flags']
          expect(req.options.proxy).to eq nil
          double(body: '{"foo": "bar"}', status: 200, headers: {})
        end
        requestor.request_all_flags()
      end
    end
  end
end
