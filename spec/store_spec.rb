require "spec_helper"

describe LaunchDarkly::ThreadSafeMemoryStore do
  subject { LaunchDarkly::ThreadSafeMemoryStore }
  let(:store) { subject.new }
  it "can read and write" do
    store.write("key", "value")
    value = store.read "key"
    expect(store.read("key")).to eq "value"
  end
end
