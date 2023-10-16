require "feature_store_spec_base"
require "spec_helper"

module LaunchDarkly
  class InMemoryStoreTester
    def create_feature_store
      InMemoryFeatureStore.new
    end
  end

  describe InMemoryFeatureStore do
    subject { InMemoryFeatureStore }

    include_examples "any_feature_store", InMemoryStoreTester.new

    it "does not provide status monitoring support" do
      store = subject.new

      expect(store.monitoring_enabled?).to be false
    end
  end
end
