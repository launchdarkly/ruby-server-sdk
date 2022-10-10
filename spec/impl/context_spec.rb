require "ldclient-rb/impl/context"

describe LaunchDarkly::Impl::Context do
  subject { LaunchDarkly::Impl::Context }

  it "can validate kind correctly" do
    test_cases = [
      [:user, false, "Kind is not a string"],
      ["kind", false, "Kind cannot be 'kind'"],
      ["multi", false, "Kind cannot be 'multi'"],
      ["user@type", false, "Kind cannot include invalid characters"],
      ["org", true, "Some kinds are valid"],
    ]

    test_cases.each do |input, expected, _descr|
      expect(subject.validate_kind(input)).to eq(expected)
    end
  end

  it "can validate a key correctly" do
    test_cases = [
      [:key, false, "Key is not a string"],
      ["", false, "Key cannot be ''"],
      ["key", true, "Some keys are valid"],
    ]

    test_cases.each do |input, expected, _descr|
      expect(subject.validate_kind(input)).to eq(expected)
    end
  end
end
