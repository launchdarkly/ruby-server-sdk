require "spec_helper"

describe LaunchDarkly::LDClient do
  subject { LaunchDarkly::LDClient }
  let(:client) do
    expect_any_instance_of(LaunchDarkly::LDClient).to receive :create_worker
    subject.new("api_key")
  end
  let(:feature) do
    data = File.read(File.join("spec", "fixtures", "feature.json"))
    JSON.parse(data, symbolize_names: true)
  end
  let(:user) do
    data = File.read(File.join("spec", "fixtures", "user.json"))
    JSON.parse(data, symbolize_names: true)
  end

  context 'user flag settings' do
    let(:config) { client.instance_variable_get :@config }
    let(:http_client) { client.instance_variable_get :@client }
    let(:setting_endpoint) { "#{config.base_uri}/api/users/#{user[:key]}/features/#{feature[:key]}" }

    describe '#update_user_flag_setting' do
      it 'requires user' do
        expect(config.logger).to receive(:error)
        client.update_user_flag_setting(nil, feature[:key], true)
      end

      it 'puts the new setting' do
        result = double('result', success?: true, status: 204)
        expect(http_client).to receive(:put).with(setting_endpoint).and_return(result)
        client.update_user_flag_setting(user[:key], feature[:key], true)
      end
    end
  end

  describe '#flush' do
    it "will flush and post all events" do
      client.instance_variable_get(:@queue).push "asdf"
      client.instance_variable_get(:@queue).push "asdf"
      expect(client).to receive(:post_flushed_events)
      client.flush
      expect(client.instance_variable_get(:@queue).length).to eq 0
    end
    it "will not do anything if there are no events" do
      expect(client).to_not receive(:post_flushed_events)
      expect(client.instance_variable_get(:@config).logger).to_not receive :error
      client.flush
    end
  end

  describe '#post_flushed_events' do
    let(:events) { ["event"] }
    it "will flush and post all events" do
      result = double("result", status: 200)
      expect(client.instance_variable_get(:@client)).to receive(:post).with(LaunchDarkly::Config.default_events_uri + "/bulk").and_return result
      expect(client.instance_variable_get(:@config).logger).to_not receive :error
      client.send(:post_flushed_events, events)
      expect(client.instance_variable_get(:@queue).length).to eq 0
    end
    it "will allow any 2XX response" do
      result = double("result", status: 202)
      expect(client.instance_variable_get(:@client)).to receive(:post).and_return result
      expect(client.instance_variable_get(:@config).logger).to_not receive :error
      client.send(:post_flushed_events, events)
    end
    it "will work with unexpected post results" do
      result = double("result", status: 418)
      expect(client.instance_variable_get(:@client)).to receive(:post).and_return result
      expect(client.instance_variable_get(:@config).logger).to receive :error
      client.send(:post_flushed_events, events)
      expect(client.instance_variable_get(:@queue).length).to eq 0
    end
  end

  describe '#toggle?' do
    it "will not fail" do
      expect(client.instance_variable_get(:@config)).to receive(:stream?).and_raise RuntimeError
      expect(client.instance_variable_get(:@config).logger).to receive(:error)
      result = client.toggle?(feature[:key], user, "default")
      expect(result).to eq "default"
    end
    it "will specify the default value in the feature request event" do
      expect(client).to receive(:add_event).with(hash_including(default: "default"))
      result = client.toggle?(feature[:key], user, "default")
    end
    it "requires user" do
      expect(client.instance_variable_get(:@config).logger).to receive(:error)
      result = client.toggle?(feature[:key], nil, "default")
      expect(result).to eq "default"
    end
    it "returns value from streamed flag if available" do
      expect(client.instance_variable_get(:@config)).to receive(:stream?).and_return(true).twice
      expect(client.instance_variable_get(:@stream_processor)).to receive(:started?).and_return true
      expect(client.instance_variable_get(:@stream_processor)).to receive(:initialized?).and_return true
      expect(client).to receive(:add_event)
      expect(client).to receive(:get_streamed_flag).and_return feature
      result = client.toggle?(feature[:key], user, "default")
      expect(result).to eq false
    end
    it "returns value from normal request if streamed flag is not available" do
      expect(client.instance_variable_get(:@config)).to receive(:stream?).and_return(false).twice
      expect(client).to receive(:add_event)
      expect(client).to receive(:get_flag_int).and_return feature
      result = client.toggle?(feature[:key], user, "default")
      expect(result).to eq false
    end
  end

  describe '#get_streamed_flag' do
    it "will not check the polled flag normally" do
      expect(client).to receive(:get_flag_stream).and_return true
      expect(client).to_not receive(:get_flag_int)
      expect(client.send(:get_streamed_flag, "key")).to eq true
    end
    context "debug stream" do
      it "will log an error if the streamed and polled flag do not match" do
        expect(client.instance_variable_get(:@config)).to receive(:debug_stream?).and_return true
        expect(client).to receive(:get_flag_stream).and_return true
        expect(client).to receive(:get_flag_int).and_return false
        expect(client.instance_variable_get(:@config).logger).to receive(:error)
        expect(client.send(:get_streamed_flag, "key")).to eq true
      end
    end
  end

  describe '#all_flags' do
    it "will parse and return the features list" do
      result = double("Faraday::Response", status: 200, body: '{"asdf":"qwer"}')
      expect(client).to receive(:make_request).with("/api/eval/features").and_return(result)
      data = client.send(:all_flags)
      expect(data).to eq(asdf: "qwer")
    end
    it "will log errors" do
      result = double("Faraday::Response", status: 418)
      expect(client).to receive(:make_request).with("/api/eval/features").and_return(result)
      expect(client.instance_variable_get(:@config).logger).to receive(:error)
      client.send(:all_flags)
    end
  end

  describe '#get_flag_int' do
    it "will return the parsed flag" do
      result = double("Faraday::Response", status: 200, body: '{"asdf":"qwer"}')
      expect(client).to receive(:make_request).with("/api/eval/features/key").and_return(result)
      data = client.send(:get_flag_int, "key")
      expect(data).to eq(asdf: "qwer")
    end
    it "will accept 401 statuses" do
      result = double("Faraday::Response", status: 401)
      expect(client).to receive(:make_request).with("/api/eval/features/key").and_return(result)
      expect(client.instance_variable_get(:@config).logger).to receive(:error)
      data = client.send(:get_flag_int, "key")
      expect(data).to be_nil
    end
    it "will accept 404 statuses" do
      result = double("Faraday::Response", status: 404)
      expect(client).to receive(:make_request).with("/api/eval/features/key").and_return(result)
      expect(client.instance_variable_get(:@config).logger).to receive(:error)
      data = client.send(:get_flag_int, "key")
      expect(data).to be_nil
    end
    it "will accept non-standard statuses" do
      result = double("Faraday::Response", status: 418)
      expect(client).to receive(:make_request).with("/api/eval/features/key").and_return(result)
      expect(client.instance_variable_get(:@config).logger).to receive(:error)
      data = client.send(:get_flag_int, "key")
      expect(data).to be_nil
    end
  end

  describe '#make_request' do
    it "will make a proper request" do
      expect(client.instance_variable_get :@client).to receive(:get)
      client.send(:make_request, "/asdf")
    end
  end

  describe '#param_for_user' do
    it "will return a consistent hash of a user key, feature key, and feature salt" do
      param = client.send(:param_for_user, feature, user)
      expect(param).to be_between(0.0, 1.0).inclusive
    end
  end

  describe '#evaluate' do
    it "will return nil if there is no feature" do
      expect(client.send(:evaluate, nil, user)).to eq nil
    end
    it "will return nil unless the feature is on" do
      feature[:on] = false
      expect(client.send(:evaluate, feature, user)).to eq nil
    end
    it "will return value if it matches the user" do
      user = { key: "Alida.Caples@example.com" }
      expect(client.send(:evaluate, feature, user)).to eq false
      user = { key: "foo@bar.com" }
      expect(client.send(:evaluate, feature, user)).to eq true
    end
    it "will return value if the target matches" do
      user = { key: "asdf@asdf.com", custom: { groups: "Microsoft" } }
      expect(client.send(:evaluate, feature, user)).to eq true
    end
    it "will return value if the weight matches" do
      expect(client).to receive(:param_for_user).and_return 0.1
      expect(client.send(:evaluate, feature, user)).to eq true
      expect(client).to receive(:param_for_user).and_return 0.9
      expect(client.send(:evaluate, feature, user)).to eq false
    end
  end

  describe '#log_timings' do
    let(:block) { lambda { "result" } }
    let(:label) { "label" }
    it "will not measure if not configured to do so" do
      expect(Benchmark).to_not receive(:measure)
      client.send(:log_timings, label, &block)
    end
    context "logging enabled" do
      before do
        expect(client.instance_variable_get(:@config)).to receive(:log_timings?).and_return true
        expect(client.instance_variable_get(:@config).logger).to receive(:debug?).and_return true
      end
      it "will benchmark timings and return result" do
        expect(Benchmark).to receive(:measure).and_call_original
        expect(client.instance_variable_get(:@config).logger).to receive(:debug)
        result = client.send(:log_timings, label, &block)
        expect(result).to eq "result"
      end
      it "will raise exceptions if the block has them" do
        block = lambda { raise RuntimeError }
        expect(Benchmark).to receive(:measure).and_call_original
        expect(client.instance_variable_get(:@config).logger).to receive(:debug)
        expect { client.send(:log_timings, label, &block) }.to raise_error RuntimeError
      end
    end
  end

  describe '#log_exception' do
    it "log error data" do
      expect(client.instance_variable_get(:@config).logger).to receive(:error)
      begin
        raise StandardError.new 'asdf'
      rescue StandardError => exn
        client.send(:log_exception, 'caller', exn)
      end
    end
  end
end
