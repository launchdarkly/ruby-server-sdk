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
  config.before(:each) do
  end
end
