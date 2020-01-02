require "spec_helper"

describe LaunchDarkly::Impl::EvaluatorBucketing do
  subject { LaunchDarkly::Impl::EvaluatorBucketing }

  describe "bucket_user" do
    it "gets expected bucket values for specific keys" do
      user = { key: "userKeyA" }
      bucket = subject.bucket_user(user, "hashKey", "key", "saltyA")
      expect(bucket).to be_within(0.0000001).of(0.42157587);

      user = { key: "userKeyB" }
      bucket = subject.bucket_user(user, "hashKey", "key", "saltyA")
      expect(bucket).to be_within(0.0000001).of(0.6708485);

      user = { key: "userKeyC" }
      bucket = subject.bucket_user(user, "hashKey", "key", "saltyA")
      expect(bucket).to be_within(0.0000001).of(0.10343106);
    end

    it "can bucket by int value (equivalent to string)" do
      user = {
        key: "userkey",
        custom: {
          stringAttr: "33333",
          intAttr: 33333
        }
      }
      stringResult = subject.bucket_user(user, "hashKey", "stringAttr", "saltyA")
      intResult = subject.bucket_user(user, "hashKey", "intAttr", "saltyA")

      expect(intResult).to be_within(0.0000001).of(0.54771423)
      expect(intResult).to eq(stringResult)
    end

    it "cannot bucket by float value" do
      user = {
        key: "userkey",
        custom: {
          floatAttr: 33.5
        }
      }
      result = subject.bucket_user(user, "hashKey", "floatAttr", "saltyA")
      expect(result).to eq(0.0)
    end


    it "cannot bucket by bool value" do
      user = {
        key: "userkey",
        custom: {
          boolAttr: true
        }
      }
      result = subject.bucket_user(user, "hashKey", "boolAttr", "saltyA")
      expect(result).to eq(0.0)
    end
  end
end
