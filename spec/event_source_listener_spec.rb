require "spec_helper"
require "support/dummy_server"

describe LaunchDarkly::EventSourceListener do
  subject { described_class }

  def dummy_server
    @dummy_server ||= DummyServer.new
  end

  before(:all) do
    dummy_server.start()
    client = HTTP.timeout(read: 2)
    retries = 0
    sleep_timeout = 1
    begin
      sleep sleep_timeout
      result = client.get("#{host}/healthcheck")
      raise if result.status.to_i != 200
    rescue
      sleep_timeout <<= 1
      retry if (retries += 1) < 3
    end
  end

  after(:all) do
    dummy_server.shutdown
  end

  let(:host) { "http://0.0.0.0:9123" }
  let(:read_timeout_second) { 2 }
  let(:default_config) { LaunchDarkly::Config.new }
  let(:headers) {
    {
      "Authorization" => "",
      "User-Agent" => "RubyClient/" + LaunchDarkly::VERSION
    }
  }

  context "when the response status is 500" do
    it "logs the error and does not call the error handler" do
      event_source_listener = subject.new(
        "#{host}/internal-server-error",
        headers: headers,
        via: default_config.proxy,
        on_retry: ->(timeout) { execution_interval = timeout },
        read_timeout: read_timeout_second,
        logger: default_config.logger
      )
      on_error_called = false
      event_source_listener.on_error do |err|
        on_error_called = true
      end

      expect(default_config.logger).to receive(:error) do |&blk|
        expect(blk.call).to eq("[LDClient] Unexpected status code 500 from streaming connection")
      end
      expect_any_instance_of(HTTP::Client).to receive(:close)
      event_source_listener.start
      expect(on_error_called).to be false
    end
  end

  context "when the response status is 401" do
    it "logs the error and calls the error handler" do
      event_source_listener = subject.new(
        "#{host}/invalid-sdk-key",
        headers: headers,
        via: default_config.proxy,
        on_retry: ->(timeout) { execution_interval = timeout },
        read_timeout: read_timeout_second,
        logger: default_config.logger
      )
      on_error_called = false
      event_source_listener.on_error do |err|
        on_error_called = true
      end

      expect(default_config.logger).to receive(:error) do |&blk|
        expect(blk.call).to eq("[LDClient] Received 401 error, SDK key is invalid")
      end
      expect_any_instance_of(HTTP::Client).to receive(:close)
      event_source_listener.start
      expect(on_error_called).to be true
    end
  end

  context "when the content type is missing" do
    it "logs the error and calls the error handler" do
      event_source_listener = subject.new(
        "#{host}/missing-content-type",
        headers: headers,
        via: default_config.proxy,
        on_retry: ->(timeout) { execution_interval = timeout },
        read_timeout: read_timeout_second,
        logger: default_config.logger
      )
      on_error_called = false
      event_source_listener.on_error do |err|
        on_error_called = true
      end

      expect(default_config.logger).to receive(:error) do |&blk|
        expect(blk.call).to eq("[LDClient] Missing Content-Type. Expected text/event-stream")
      end
      expect_any_instance_of(HTTP::Client).to receive(:close)
      event_source_listener.start
      expect(on_error_called).to be true
    end
  end

  context "when the content type is wrong" do
    it "logs the error and calls the error handler" do
      event_source_listener = subject.new(
        "#{host}/invalid-content-type",
        headers: headers,
        via: default_config.proxy,
        on_retry: ->(timeout) { execution_interval = timeout },
        read_timeout: read_timeout_second,
        logger: default_config.logger
      )
      on_error_called = false
      event_source_listener.on_error do |err|
        on_error_called = true
      end

      expect(default_config.logger).to receive(:error) do |&blk|
        expect(blk.call).to eq("[LDClient] Received text/html; charset=utf-8 Content-Type. Expected text/event-stream")
      end
      expect_any_instance_of(HTTP::Client).to receive(:close)
      event_source_listener.start
      expect(on_error_called).to be true
    end
  end

  context "when the response is valid" do
    it "dispatches the events until the connection is closed due to read timeout" do
      event_source_listener = subject.new(
        "#{host}/sse",
        headers: headers,
        via: default_config.proxy,
        on_retry: ->(timeout) { execution_interval = timeout },
        read_timeout: read_timeout_second,
        logger: default_config.logger
      )
      on_error_called = false
      put_received = false
      patch_received = false
      delete_received = false
      event_source_listener.on("put") { |message| put_received = true }
      event_source_listener.on("patch") { |message| patch_received = true }
      event_source_listener.on("delete") { |message| delete_received = true }
      event_source_listener.on_error do |err|
        on_error_called = true
      end

      expect_any_instance_of(HTTP::Client).to receive(:close)
      event_source_listener.start
      expect(put_received).to be true
      expect(patch_received).to be true
      expect(delete_received).to be false
      expect(on_error_called).to be false
    end
  end

  context "when called with a proxy" do
    let(:proxy_host) { "web-proxy.example.org" }
    let(:proxy_port) { 8080 }
    let(:proxy_user) { "user" }
    let(:proxy_password) { "password" }

    it "parses correctly the proxy options" do
      event_source_listener = subject.new(
        "#{host}/healthcheck",
        headers: headers,
        via: "http://#{proxy_user}:#{proxy_password}@#{proxy_host}:#{proxy_port}",
        on_retry: ->(timeout) { execution_interval = timeout },
        read_timeout: read_timeout_second,
        logger: default_config.logger
      )
      expect_any_instance_of(HTTP::Client).to receive(
        :via
      ).with(proxy_host, proxy_port, proxy_user, proxy_password).and_call_original
      event_source_listener.start
    end
  end
end
