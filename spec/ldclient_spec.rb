require 'spec_helper'

describe LaunchDarkly::LDClient do
  subject { LaunchDarkly::LDClient }
  let(:client) do
    expect_any_instance_of(LaunchDarkly::LDClient).to receive :create_worker
    subject.new('api_key')
  end

  describe '#flush' do
    it 'will flush and post all events' do
      client.instance_variable_get(:@queue).push 'asdf'
      client.instance_variable_get(:@queue).push 'asdf'
      result = double('result', status: 200)
      expect(client.instance_variable_get(:@client)).to receive(:post).and_return result
      client.flush
      expect(client.instance_variable_get(:@queue).length).to eq 0
    end
    it 'will work with unexpected post results' do
      client.instance_variable_get(:@queue).push 'asdf'
      client.instance_variable_get(:@queue).push 'asdf'
      result = double('result', status: 500)
      expect(client.instance_variable_get(:@client)).to receive(:post).and_return result
      expect(client.instance_variable_get(:@config).logger).to receive :error
      client.flush
      expect(client.instance_variable_get(:@queue).length).to eq 0
    end
    it 'will not do anything if there are no events' do
      expect(client.instance_variable_get(:@client)).to_not receive(:post)
      expect(client.instance_variable_get(:@config).logger).to_not receive :error
      client.flush
    end
  end
end
