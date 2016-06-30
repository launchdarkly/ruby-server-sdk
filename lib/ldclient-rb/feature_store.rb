require "concurrent/atomics"

module LaunchDarkly
  
  class InMemoryFeatureStore
    def initialize
      @features = Hash.new
      @lock = Concurrent::ReadWriteLock.new
      @initialized = Concurrent::AtomicBoolean.new(false)
    end

    def get(key)
      @lock.with_read_lock do
        f = @features[key.to_sym]
        (f.nil? || f[:deleted]) ? nil : f
      end
    end

    def all
      @lock.with_read_lock do
        @features.select { |_k, f| not f[:deleted] }
      end
    end

    def delete(key, version)
      @lock.with_write_lock do
        old = @features[key.to_sym]

        if !old.nil? && old[:version] < version
          old[:deleted] = true
          old[:version] = version
          @features[key.to_sym] = old
        elsif old.nil?
          @features[key.to_sym] = { deleted: true, version: version }
        end
      end
    end

    def init(fs)
      @lock.with_write_lock do
        @features.replace(fs)
        @initialized.make_true
      end
    end

    def upsert(key, feature)
      @lock.with_write_lock do
        old = @features[key.to_sym]

        if old.nil? || old[:version] < feature[:version]
          @features[key.to_sym] = feature
        end
      end
    end

    def initialized?
      @initialized.value
    end
  end
end