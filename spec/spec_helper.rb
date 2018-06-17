require "codeclimate-test-reporter"
CodeClimate::TestReporter.start

require "ldclient-rb"

RSpec.configure do |config|
  config.before(:each) do
  end
end

Dir["./spec/support/**/*.rb"].each { |fn| require fn }
