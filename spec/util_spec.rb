require "spec_helper"

describe LaunchDarkly::Util do
  describe 'log_exception' do
    let(:logger) { double() }

    it "logs error data" do
      expect(logger).to receive(:error)
      expect(logger).to receive(:debug)
      begin
        raise StandardError.new 'asdf'
      rescue StandardError => exn
        LaunchDarkly::Util.log_exception(logger, "message", exn)
      end
    end
  end
end
