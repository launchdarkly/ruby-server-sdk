require 'concurrent'
require "ldclient-rb/interfaces"
require "ldclient-rb/impl/data_store/data_kind"

module LaunchDarkly
  module Impl
    module DataStore
        FEATURES = LaunchDarkly::Interfaces::DataStore::FEATURES
        SEGMENTS = LaunchDarkly::Interfaces::DataStore::SEGMENTS
        ALL_KINDS = LaunchDarkly::Interfaces::DataStore::ALL_KINDS
    end
  end
end