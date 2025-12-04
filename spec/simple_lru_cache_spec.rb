require "ldclient-rb/impl/simple_lru_cache"
require "spec_helper"

module LaunchDarkly
  describe Impl::SimpleLRUCacheSet do
    subject { Impl::SimpleLRUCacheSet }

    it "retains values up to capacity" do
      lru = subject.new(3)
      expect(lru.add("a")).to be false
      expect(lru.add("b")).to be false
      expect(lru.add("c")).to be false
      expect(lru.add("a")).to be true
      expect(lru.add("b")).to be true
      expect(lru.add("c")).to be true
    end

    it "discards oldest value on overflow" do
      lru = subject.new(2)
      expect(lru.add("a")).to be false
      expect(lru.add("b")).to be false
      expect(lru.add("a")).to be true
      expect(lru.add("c")).to be false  # b is discarded as oldest
      expect(lru.add("b")).to be false
    end
  end
end
