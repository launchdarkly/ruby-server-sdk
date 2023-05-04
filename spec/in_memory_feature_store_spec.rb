require "feature_store_spec_base"
require "spec_helper"

class InMemoryStoreTester
  def create_feature_store
    LaunchDarkly::InMemoryFeatureStore.new
  end
end

describe LaunchDarkly::InMemoryFeatureStore do
  subject { LaunchDarkly::InMemoryFeatureStore }

  include_examples "any_feature_store", InMemoryStoreTester.new

  it "does not provide status monitoring support" do
    store = subject.new

    expect(store.monitoring_enabled?).to be false
  end
end
