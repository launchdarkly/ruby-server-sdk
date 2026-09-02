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

#
# A test listener that records every event it receives.
#
# A data source can deliver events from its own thread. A spec that starts a
# data source and then reads `statuses` at once can run before the event
# arrives. Use `wait_for_count` or `wait_for_status` to block until the events
# you expect have arrived, then assert on the returned array.
#
class ListenerSpy
  def initialize
    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @statuses = []
  end

  #
  # Returns a copy of the events received so far.
  #
  # @return [Array]
  #
  def statuses
    @mutex.synchronize { @statuses.dup }
  end

  def update(status)
    @mutex.synchronize do
      @statuses << status
      @condition.broadcast
    end
  end

  #
  # Blocks until at least `count` events have arrived, or until the timeout
  # passes. Returns a copy of the events received so far. The caller must
  # still assert on the result; this method does not fail on timeout.
  #
  # @param count [Integer] the number of events to wait for
  # @param timeout [Numeric] the maximum time to wait, in seconds
  # @return [Array]
  #
  def wait_for_count(count, timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    @mutex.synchronize do
      while @statuses.count < count
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0
        @condition.wait(@mutex, remaining)
      end
      @statuses.dup
    end
  end

  #
  # Blocks until at least one event has arrived, or until the timeout passes.
  #
  # @param timeout [Numeric] the maximum time to wait, in seconds
  # @return [Array]
  #
  def wait_for_status(timeout: 2)
    wait_for_count(1, timeout: timeout)
  end
end


RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.max_formatted_output_length = 1000 # otherwise rspec tends to abbreviate our failure output and make it unreadable
  end
  config.before(:each) do
  end
end
