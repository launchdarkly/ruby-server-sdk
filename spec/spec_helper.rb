require "simplecov" if ENV['LD_ENABLE_CODE_COVERAGE'] == '1'

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

class SynchronousExecutor
  def post
    yield
  end
end

class CallbackListener
  def initialize(callable)
    @callable = callable
  end

  def update(status)
    @callable.call(status)
  end
end

class ListenerSpy
  attr_reader :statuses

  def initialize
    @statuses = []
  end

  def update(status)
    @statuses << status
  end
end


RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.max_formatted_output_length = 1000 # otherwise rspec tends to abbreviate our failure output and make it unreadable
  end
  config.before(:each) do
  end
end
