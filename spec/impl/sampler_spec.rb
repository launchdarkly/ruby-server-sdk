require "ldclient-rb/impl/sampler"

module LaunchDarkly
  module Impl
    describe Sampler do
      it "samples false for non-integer values" do
        sampler = Sampler.new(Random.new)
        ["not an int", true, 3.0].each do |value|
          expect(sampler.sample(value)).to be(false)
        end
      end

      it "non-positive ints are considered false" do
        sampler = Sampler.new(Random.new)
        (-10..0).each do |value|
          expect(sampler.sample(value)).to be(false)
        end
      end

      it "one is true" do
        expect(Sampler.new(Random.new).sample(1)).to be(true)
      end

      it "can control sampling ratio" do
        count = 0
        sampler = Sampler.new(Random.new(0))
        sampled = 1_000.times.select { |_| sampler.sample(10) }

        expect(sampled.size).to eq(98)
      end
    end
  end
end
