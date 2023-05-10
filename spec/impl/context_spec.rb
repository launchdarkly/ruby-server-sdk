require "ldclient-rb/impl/context"

module LaunchDarkly
  module Impl
    describe Context do
      subject { Context }

      it "can validate kind correctly" do
        test_cases = [
          [:user_context, Context::ERR_KIND_NON_STRING],
          ["kind", Context::ERR_KIND_CANNOT_BE_KIND],
          ["multi", Context::ERR_KIND_CANNOT_BE_MULTI],
          ["user@type", Context::ERR_KIND_INVALID_CHARS],
          ["org", nil],
        ]

        test_cases.each do |input, expected|
          expect(subject.validate_kind(input)).to eq(expected)
        end
      end

      it "can validate a key correctly" do
        test_cases = [
          [:key, Context::ERR_KEY_NON_STRING],
          ["", Context::ERR_KEY_EMPTY],
          ["key", nil],
        ]

        test_cases.each do |input, expected|
          expect(subject.validate_key(input)).to eq(expected)
        end
      end
    end
  end
end
