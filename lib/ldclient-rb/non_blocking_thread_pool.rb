require "concurrent"
require "concurrent/atomics"
require "concurrent/executors"
require "thread"

module LaunchDarkly
  # Simple wrapper for a FixedThreadPool that rejects new jobs if all the threads are busy, rather
  # than blocking. Also provides a way to wait for all jobs to finish without shutting down.
  # @private
  class NonBlockingThreadPool
    def initialize(capacity)
      @capacity = capacity
      @pool = Concurrent::FixedThreadPool.new(capacity)
      @semaphore = Concurrent::Semaphore.new(capacity)
    end

    # Attempts to submit a job, but only if a worker is available. Unlike the regular post method,
    # this returns a value: true if the job was submitted, false if all workers are busy.
    def post
      unless @semaphore.try_acquire(1)
        return
      end
      @pool.post do
        begin
          yield
        ensure
          @semaphore.release(1)
        end
      end
    end

    # Waits until no jobs are executing, without shutting down the pool.
    def wait_all
      @semaphore.acquire(@capacity)
      @semaphore.release(@capacity)
    end

    def shutdown
      @pool.shutdown
    end

    def wait_for_termination
      @pool.wait_for_termination
    end
  end
end
