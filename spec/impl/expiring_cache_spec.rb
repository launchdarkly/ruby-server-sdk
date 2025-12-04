require 'spec_helper'
require 'timecop'
require "ldclient-rb/impl/expiring_cache"

module LaunchDarkly
  describe Impl::ExpiringCache do
    subject { Impl::ExpiringCache }

    before(:each) do
      Timecop.freeze(Time.now)
    end

    after(:each) do
      Timecop.return
    end

    it "evicts entries based on TTL" do
      c = subject.new(3, 300)
      c[:a] = 1
      c[:b] = 2

      Timecop.freeze(Time.now + 330)

      c[:c] = 3

      expect(c[:a]).to be nil
      expect(c[:b]).to be nil
      expect(c[:c]).to eq 3
    end

    it "evicts entries based on max size" do
      c = subject.new(3, 300)
      c[:a] = 1
      c[:b] = 2
      c[:c] = 3
      c[:d] = 4

      expect(c[:a]).to be nil
      expect(c[:b]).to eq 2
      expect(c[:c]).to eq 3
      expect(c[:d]).to eq 4
    end

    it "resets TTL on put" do
      c = subject.new(3, 300)
      c[:a] = 1
      c[:b] = 2

      Timecop.freeze(Time.now + 250)

      c[:a] = 1.5

      Timecop.freeze(Time.now + 100)

      c[:c] = 3

      expect(c[:a]).to eq 1.5
      expect(c[:b]).to be nil
      expect(c[:c]).to eq 3
    end

    it "resets LRU on put" do
      c = subject.new(3, 300)
      c[:a] = 1
      c[:b] = 2
      c[:c] = 3
      c[:a] = 1.5
      c[:d] = 4

      expect(c[:a]).to eq 1.5
      expect(c[:b]).to be nil
      expect(c[:c]).to eq 3
      expect(c[:d]).to eq 4
    end

    it "does not reset LRU on get" do
      c = subject.new(3, 300)
      c[:a] = 1
      c[:b] = 2
      c[:c] = 3
      c[:a]
      c[:d] = 4

      expect(c[:a]).to be nil
      expect(c[:b]).to eq 2
      expect(c[:c]).to eq 3
      expect(c[:d]).to eq 4
    end
  end
end

