require "concurrent/atomics"

module LaunchDarkly
  class InMemoryVersionedStore
    def initialize
      @items = Hash.new
      @lock = Concurrent::ReadWriteLock.new
      @initialized = Concurrent::AtomicBoolean.new(false)
    end

    def get(key)
      @lock.with_read_lock do
        f = @items[key.to_sym]
        (f.nil? || f[:deleted]) ? nil : f
      end
    end

    def all
      @lock.with_read_lock do
        @items.select { |_k, f| not f[:deleted] }
      end
    end

    def delete(key, version)
      @lock.with_write_lock do
        old = @items[key.to_sym]

        if !old.nil? && old[:version] < version
          old[:deleted] = true
          old[:version] = version
          @items[key.to_sym] = old
        elsif old.nil?
          @items[key.to_sym] = { deleted: true, version: version }
        end
      end
    end

    def init(fs)
      @lock.with_write_lock do
        @items.replace(fs)
        @initialized.make_true
      end
    end

    def upsert(key, feature)
      @lock.with_write_lock do
        old = @items[key.to_sym]

        if old.nil? || old[:version] < feature[:version]
          @items[key.to_sym] = feature
        end
      end
    end

    def initialized?
      @initialized.value
    end

    def stop
      # nothing to do
    end
  end

  class InMemoryFeatureStore < InMemoryVersionedStore
  end
  
  class InMemorySegmentStore < InMemoryVersionedStore
  end
end
