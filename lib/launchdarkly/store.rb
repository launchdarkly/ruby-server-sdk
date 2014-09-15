require 'thread_safe'

module Launchdarkly
  class ThreadSafeMemoryStore
    def initialize
      @cache = ThreadSafe::Cache.new
    end

    def read(key)
      @cache[key]
    end

    def write(key, value)
      @cache[key] = value
    end
  end
end
