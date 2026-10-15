require "ldclient-rb/impl/util"
require "spec_helper"

module LaunchDarkly
  module Impl
    describe Util do
      describe 'log_exception' do
        let(:logger) { double }

        it "logs error data" do
          expect(logger).to receive(:error)
          expect(logger).to receive(:debug)
          begin
            raise StandardError.new 'asdf'
          rescue StandardError => exn
            Util.log_exception(logger, "message", exn)
          end
        end
      end

      describe ".classify_http_status" do
        [400, 408, 429, 500, 502, 503, 504, 599, 304].each do |status|
          it "classifies #{status} as normal" do
            expect(Util.classify_http_status(status)).to eq(:normal)
            expect(Util.http_error_recoverable?(status)).to be true
          end
        end

        [401, 403, 404, 405, 409, 410, 499].each do |status|
          it "classifies #{status} as unexpected" do
            expect(Util.classify_http_status(status)).to eq(:unexpected)
            expect(Util.http_error_recoverable?(status)).to be false
          end
        end
      end

      describe "payload filter key validation" do
        let(:logger) { double }

        it "silently discards nil" do
          expect(logger).not_to receive(:warn)
          expect(Util.validate_payload_filter_key(nil, logger)).to be_nil
        end

        [true, 1, 1.0, [], {}].each do |value|
          it "returns nil for invalid type #{value.class}" do
            expect(logger).to receive(:warn)
            expect(Util.validate_payload_filter_key(value, logger)).to be_nil
          end
        end

        [
          "",
          "-cannot-start-with-dash",
          "_cannot-start-with-underscore",
          "-cannot-start-with-period",
          "no spaces for you",
          "org@special/characters",
        ].each do |value|
          it "returns nil for invalid value #{value}" do
            expect(logger).to receive(:warn)
            expect(Util.validate_payload_filter_key(value, logger)).to be_nil
          end
        end

        [
          "camelCase",
          "snake_case",
          "kebab-case",
          "with.dots",
          "with_underscores",
          "with-hyphens",
          "with1234numbers",
          "with.many_1234-mixtures",
          "1start-with-number",
        ].each do |value|
          it "passes for value #{value}" do
            expect(logger).not_to receive(:warn)
            expect(Util.validate_payload_filter_key(value, logger)).to eq(value)
          end
        end
      end
    end
  end
end
