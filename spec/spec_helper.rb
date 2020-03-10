require "codeclimate-test-reporter"
CodeClimate::TestReporter.start

require "ldclient-rb"

$null_log = ::Logger.new($stdout)
$null_log.level = ::Logger::FATAL

RSpec.configure do |config|
  config.before(:each) do
  end
end
