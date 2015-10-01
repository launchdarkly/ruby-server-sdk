require 'codeclimate-test-reporter'
CodeClimate::TestReporter.start

require 'ldclient-rb'

RSpec.configure do |config|
  config.before(:each) do
  end
end
