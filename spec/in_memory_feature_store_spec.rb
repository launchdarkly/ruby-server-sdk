require "feature_store_spec_base"
require "spec_helper"

def create_in_memory_store(opts = {})
  LaunchDarkly::InMemoryFeatureStore.new
end

describe LaunchDarkly::InMemoryFeatureStore do
  subject { LaunchDarkly::InMemoryFeatureStore }
  
  include_examples "feature_store", method(:create_in_memory_store)
end
