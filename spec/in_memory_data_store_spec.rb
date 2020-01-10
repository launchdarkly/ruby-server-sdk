require "data_store_spec_base"
require "spec_helper"

def create_in_memory_store(opts = {})
  LaunchDarkly::InMemoryDataStore.new
end

describe LaunchDarkly::InMemoryDataStore do
  subject { LaunchDarkly::InMemoryDataStore }
  
  include_examples "data_store", method(:create_in_memory_store)
end
