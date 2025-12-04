require "spec_helper"

module LaunchDarkly
  describe Impl::ThreadSafeMemoryStore do
    subject { Impl::ThreadSafeMemoryStore }
    let(:store) { subject.new }
    it "can read and write" do
      store.write("key", "value")
      expect(store.read("key")).to eq "value"
    end
  end
end
