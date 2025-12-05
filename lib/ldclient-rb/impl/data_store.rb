require 'concurrent'
require "ldclient-rb/interfaces"
require "ldclient-rb/impl/data_store/data_kind"

module LaunchDarkly
  module Impl
    module DataStore
        # These constants denote the types of data that can be stored in the feature store.  If
        # we add another storable data type in the future, as long as it follows the same pattern
        # (having "key", "version", and "deleted" properties), we only need to add a corresponding
        # constant here and the existing store should be able to handle it.
        #
        # The :priority and :get_dependency_keys properties are used by FeatureStoreDataSetSorter
        # to ensure data consistency during non-atomic updates.

        # @api private
        FEATURES = DataKind.new(namespace: "features", priority: 1).freeze

        # @api private
        SEGMENTS = DataKind.new(namespace: "segments", priority: 0).freeze

        # @api private
        ALL_KINDS = [FEATURES, SEGMENTS].freeze
    end
  end
end