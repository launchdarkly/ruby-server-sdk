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

      it "compares attribute names in either direction" do
        [
          [:email, "email"],
          ["email", :email],
          [:email, :email],
          ["email", "email"],
        ].each do |(component, key)|
          expect(subject.same_attribute_name?(component, key)).to be true
        end

        expect(subject.same_attribute_name?(:email, "other")).to be false
      end

      it "fetches an attribute for either key type by either name type" do
        [
          [{ email: "value" }, :email],
          [{ email: "value" }, "email"],
          [{ "email" => "value" }, :email],
          [{ "email" => "value" }, "email"],
        ].each do |(hash, name)|
          expect(subject.fetch_attribute(hash, name)).to eq([true, "value"])
        end

        expect(subject.fetch_attribute({ email: "value" }, :other)).to eq([false, nil])
      end

      it "prefers an exact match when a hash holds both forms of a name" do
        hash = { :email => "symbol", "email" => "string" }

        expect(subject.fetch_attribute(hash, :email)).to eq([true, "symbol"])
        expect(subject.fetch_attribute(hash, "email")).to eq([true, "string"])
      end

      it "reports a missing attribute as absent rather than nil valued" do
        expect(subject.fetch_attribute({ email: nil }, :email)).to eq([true, nil])
        expect(subject.fetch_attribute({}, :email)).to eq([false, nil])
      end
    end
  end
end
