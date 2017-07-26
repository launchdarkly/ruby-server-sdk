require "spec_helper"
require "faraday"

describe LaunchDarkly::Requestor do
  describe ".request_all_flags" do
    describe "with a proxy" do
      let(:requestor) {
        LaunchDarkly::Requestor.new(
          "key",
          LaunchDarkly::Config.new({
            :proxy => "http://proxy.com",
            :base_uri => "http://ld.com"
          })
        )
      }
      it "converts the proxy option" do
        faraday = Faraday.new
        requestor.instance_variable_set(:@client, faraday)
        allow(faraday).to receive(:get) do |*args, &block|
          req = double(Faraday::Request, :headers => {}, :options => Faraday::RequestOptions.new)
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
            :base_uri => "http://ld.com"
          })
        )
      }
      it "converts the proxy option" do
        faraday = Faraday.new
        requestor.instance_variable_set(:@client, faraday)
        allow(faraday).to receive(:get) do |*args, &block|
          req = double(Faraday::Request, :headers => {}, :options => Faraday::RequestOptions.new)
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
