require "ldclient-rb/impl/context"

describe LaunchDarkly::Impl::Context do
  subject { LaunchDarkly::Impl::Context }

  it "can validate kind correctly" do
    test_cases = [
      [:user_context, LaunchDarkly::Impl::Context::ERR_KIND_NON_STRING],
      ["kind", LaunchDarkly::Impl::Context::ERR_KIND_CANNOT_BE_KIND],
      ["multi", LaunchDarkly::Impl::Context::ERR_KIND_CANNOT_BE_MULTI],
      ["user@type", LaunchDarkly::Impl::Context::ERR_KIND_INVALID_CHARS],
      ["org", nil],
    ]

    test_cases.each do |input, expected|
      expect(subject.validate_kind(input)).to eq(expected)
    end
  end

  it "can validate a key correctly" do
    test_cases = [
      [:key, LaunchDarkly::Impl::Context::ERR_KEY_NON_STRING],
      ["", LaunchDarkly::Impl::Context::ERR_KEY_EMPTY],
      ["key", nil],
    ]

    test_cases.each do |input, expected|
      expect(subject.validate_key(input)).to eq(expected)
    end
  end
end