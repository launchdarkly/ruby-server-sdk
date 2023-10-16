require "spec_helper"

module LaunchDarkly
  describe ThreadSafeMemoryStore do
    subject { ThreadSafeMemoryStore }
    let(:store) { subject.new }
    it "can read and write" do
      store.write("key", "value")
      expect(store.read("key")).to eq "value"
    end
  end
end
