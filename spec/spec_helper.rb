require "ldclient-rb"

$null_log = ::Logger.new($stdout)
$null_log.level = ::Logger::FATAL

def ensure_close(thing)
  begin
    yield thing
  ensure
    thing.close
  end
end

def ensure_stop(thing)
  begin
    yield thing
  ensure
    thing.stop
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.max_formatted_output_length = 1000 # otherwise rspec tends to abbreviate our failure output and make it unreadable
  end
  config.before(:each) do
  end
end
