require "concurrent/atomics"

module LaunchDarkly
  FEATURES = {
    namespace: "features"
  }

  SEGMENTS = {
    namespace: "segments"
  }

  class InMemoryFeatureStore
    def initialize
      @items = Hash.new
      @lock = Concurrent::ReadWriteLock.new
      @initialized = Concurrent::AtomicBoolean.new(false)
    end

    def get(kind, key)
      @lock.with_read_lock do
        coll = @items[kind]
        f = coll.nil? ? nil : coll[key.to_sym]
        (f.nil? || f[:deleted]) ? nil : f
      end
    end

    def all(kind)
      @lock.with_read_lock do
        coll = @items[kind]
        (coll.nil? ? Hash.new : coll).select { |_k, f| not f[:deleted] }
      end
    end

    def delete(kind, key, version)
      @lock.with_write_lock do
        coll = @items[kind]
        if coll.nil?
          coll = Hash.new
          @items[kind] = coll
        end
        old = coll[key.to_sym]

        if old.nil? || old[:version] < version
          coll[key.to_sym] = { deleted: true, version: version }
        end
      end
    end

    def init(allData)
      @lock.with_write_lock do
        @items.replace(allData)
        @initialized.make_true
      end
    end

    def upsert(kind, item)
      @lock.with_write_lock do
        coll = @items[kind]
        if coll.nil?
          coll = Hash.new
          @items[kind] = coll
        end
        old = coll[item[:key].to_sym]

        if old.nil? || old[:version] < item[:version]
          coll[item[:key].to_sym] = item
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
end
