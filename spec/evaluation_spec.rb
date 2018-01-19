require "spec_helper"

describe LaunchDarkly::Evaluation do
  subject { LaunchDarkly::Evaluation }

  include LaunchDarkly::Evaluation

  describe "bucket_user" do
    it "can bucket by int value (equivalent to string)" do
      user = {
        key: "userkey",
        custom: {
          stringAttr: "33333",
          intAttr: 33333
        }
      }
      stringResult = bucket_user(user, "key", "stringAttr", "salt")
      intResult = bucket_user(user, "key", "intAttr", "salt")
      expect(intResult).to eq(stringResult)
    end

    it "cannot bucket by float value" do
      user = {
        key: "userkey",
        custom: {
          floatAttr: 33.5
        }
      }
      result = bucket_user(user, "key", "floatAttr", "salt")
      expect(result).to eq(0.0)
    end


    it "cannot bucket by bool value" do
      user = {
        key: "userkey",
        custom: {
          boolAttr: true
        }
      }
      result = bucket_user(user, "key", "boolAttr", "salt")
      expect(result).to eq(0.0)
    end
  end
end
