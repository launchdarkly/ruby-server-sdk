require "ldclient-rb/interfaces"
require "ldclient-rb/impl/store_data_set_sorter"

module LaunchDarkly
  module Impl
    #
    # Provides additional behavior that the client requires before or after feature store operations.
    # Currently this just means sorting the data set for init(). In the future we may also use this
    # to provide an update listener capability.
    #
    class FeatureStoreClientWrapper
      include Interfaces::FeatureStore

      def initialize(store)
        @store = store
      end

      def init(all_data)
        @store.init(FeatureStoreDataSetSorter.sort_all_collections(all_data))
      end

      def get(kind, key)
        @store.get(kind, key)
      end

      def all(kind)
        @store.all(kind)
      end

      def upsert(kind, item)
        @store.upsert(kind, item)
      end

      def delete(kind, key, version)
        @store.delete(kind, key, version)
      end

      def initialized?
        @store.initialized?
      end

      def stop
        @store.stop
      end
    end
  end
end
