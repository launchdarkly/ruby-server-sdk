require "segment_store_spec_base"
require "spec_helper"

def create_in_memory_store()
  LaunchDarkly::InMemorySegmentStore.new
end

describe LaunchDarkly::InMemorySegmentStore do
  subject { LaunchDarkly::InMemorySegmentStore }
  
  include_examples "segment_store", method(:create_in_memory_store)
end
