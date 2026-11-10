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
    end
  end
end
