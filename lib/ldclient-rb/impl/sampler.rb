module LaunchDarkly
  module Impl
    class Sampler
      #
      # @param random [Random]
      #
      def initialize(random)
        @random = random
      end

      #
      # @param ratio [Int]
      #
      # @return [Boolean]
      #
      def sample(ratio)
        return false unless ratio.is_a? Integer
        return false if ratio <= 0
        return true if ratio == 1

        @random.rand(1.0) < 1.0 / ratio
      end
    end
  end
end
