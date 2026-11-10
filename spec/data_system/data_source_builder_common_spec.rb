# frozen_string_literal: true

require "spec_helper"

module LaunchDarkly
  module DataSystem
    {
      PollingDataSourceBuilder => :base_uri,
      FDv1PollingDataSourceBuilder => :base_uri,
      StreamingDataSourceBuilder => :stream_uri,
    }.each do |builder_class, uri_option|
      RSpec.describe builder_class do
        let(:socket_factory) { double("socket factory") }

        def http_config_of(builder, config)
          http_config = nil
          allow(Impl::DataSystem::HttpConfigOptions).to receive(:new).and_wrap_original do |original, **args|
            http_config = original.call(**args)
          end
          builder.build("sdk-key", config)
          http_config
        end

        it "uses the default URI and HTTP options" do
          config = Config.new(logger: $null_log)
          http_config = http_config_of(described_class.new, config)

          expect(http_config.base_uri).to eq described_class::DEFAULT_BASE_URI
          expect(http_config.socket_factory).to be_nil
          expect(http_config.read_timeout).to eq Config.default_read_timeout
          expect(http_config.connect_timeout).to eq Config.default_connect_timeout
        end

        it "uses the URI and HTTP options from the SDK configuration" do
          config = Config.new(
            logger: $null_log,
            uri_option => "https://relay.example.com/",
            socket_factory: socket_factory,
            read_timeout: 15,
            connect_timeout: 4
          )
          http_config = http_config_of(described_class.new, config)

          expect(http_config.base_uri).to eq "https://relay.example.com"
          expect(http_config.socket_factory).to be socket_factory
          expect(http_config.read_timeout).to eq 15
          expect(http_config.connect_timeout).to eq 4
        end

        it "uses the builder settings in place of the SDK configuration" do
          config = Config.new(
            logger: $null_log,
            uri_option => "https://relay.example.com",
            socket_factory: double("config socket factory"),
            read_timeout: 15,
            connect_timeout: 4
          )
          builder = described_class.new
            .base_uri("https://builder.example.com/")
            .socket_factory(socket_factory)
            .read_timeout(20)
            .connect_timeout(6)
          http_config = http_config_of(builder, config)

          expect(http_config.base_uri).to eq "https://builder.example.com"
          expect(http_config.socket_factory).to be socket_factory
          expect(http_config.read_timeout).to eq 20
          expect(http_config.connect_timeout).to eq 6
        end
      end
    end
  end
end
