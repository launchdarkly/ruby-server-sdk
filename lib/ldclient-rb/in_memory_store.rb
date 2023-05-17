require "concurrent/atomics"

module LaunchDarkly

  # These constants denote the types of data that can be stored in the feature store.  If
  # we add another storable data type in the future, as long as it follows the same pattern
  # (having "key", "version", and "deleted" properties), we only need to add a corresponding
  # constant here and the existing store should be able to handle it.
  #
  # The :priority and :get_dependency_keys properties are used by FeatureStoreDataSetSorter
  # to ensure data consistency during non-atomic updates.

  # @private
  FEATURES = {
    namespace: "features",
    priority: 1,  # that is, features should be stored after segments
    get_dependency_keys: lambda { |flag| (flag[:prerequisites] || []).map { |p| p[:key] } },
  }.freeze

  # @private
  SEGMENTS = {
    namespace: "segments",
    priority: 0,
  }.freeze

  # @private
  ALL_KINDS = [FEATURES, SEGMENTS].freeze

  #
  # Default implementation of the LaunchDarkly client's feature store, using an in-memory
  # cache.  This object holds feature flags and related data received from LaunchDarkly.
  # Database-backed implementations are available in {LaunchDarkly::Integrations}.
  #
  class InMemoryFeatureStore
    include LaunchDarkly::Interfaces::FeatureStore

    def initialize
      @items = Hash.new
      @lock = Concurrent::ReadWriteLock.new
      @initialized = Concurrent::AtomicBoolean.new(false)
    end

    def monitoring_enabled?
      false
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

    def init(all_data)
      @lock.with_write_lock do
        @items.replace(all_data)
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
