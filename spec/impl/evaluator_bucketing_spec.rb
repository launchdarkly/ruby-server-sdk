require "spec_helper"

describe LaunchDarkly::Impl::EvaluatorBucketing do
  subject { LaunchDarkly::Impl::EvaluatorBucketing }

  describe "bucket_user" do
    describe "seed exists" do
      let(:seed) { 61 }
      it "gets the expected bucket values for seed" do
        user = { key: "userKeyA" }
        bucket = subject.bucket_user(user, "hashKey", "key", "saltyA", seed)
        expect(bucket).to be_within(0.0000001).of(0.09801207);

        user = { key: "userKeyB" }
        bucket = subject.bucket_user(user, "hashKey", "key", "saltyA", seed)
        expect(bucket).to be_within(0.0000001).of(0.14483777);

        user = { key: "userKeyC" }
        bucket = subject.bucket_user(user, "hashKey", "key", "saltyA", seed)
        expect(bucket).to be_within(0.0000001).of(0.9242641);
      end

      it "should return the same bucket if the seed and user is the same" do
        user = { key: "userKeyA" }
        bucket1 = subject.bucket_user(user, "hashKey", "bucket_by", "saltyA", seed)
        bucket2 = subject.bucket_user(user, "hashKey1", "bucket_by", "saltyB", seed)
        bucket3 = subject.bucket_user(user, "hashKey2", "bucket_by", "saltyC", seed)
        expect(bucket1).to eq(bucket2)
        expect(bucket2).to eq(bucket3)
      end
    end

    it "gets expected bucket values for specific keys" do
      user = { key: "userKeyA" }
      bucket = subject.bucket_user(user, "hashKey", "key", "saltyA", nil)
      expect(bucket).to be_within(0.0000001).of(0.42157587);

      user = { key: "userKeyB" }
      bucket = subject.bucket_user(user, "hashKey", "key", "saltyA", nil)
      expect(bucket).to be_within(0.0000001).of(0.6708485);

      user = { key: "userKeyC" }
      bucket = subject.bucket_user(user, "hashKey", "key", "saltyA", nil)
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
      stringResult = subject.bucket_user(user, "hashKey", "stringAttr", "saltyA", nil)
      intResult = subject.bucket_user(user, "hashKey", "intAttr", "saltyA", nil)

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
      result = subject.bucket_user(user, "hashKey", "floatAttr", "saltyA", nil)
      expect(result).to eq(0.0)
    end


    it "cannot bucket by bool value" do
      user = {
        key: "userkey",
        custom: {
          boolAttr: true
        }
      }
      result = subject.bucket_user(user, "hashKey", "boolAttr", "saltyA", nil)
      expect(result).to eq(0.0)
    end
  end

  describe "variation_index_for_user" do
    it "matches bucket" do
      user = { key: "userkey" }
      flag_key = "flagkey"
      salt = "salt"

      # First verify that with our test inputs, the bucket value will be greater than zero and less than 100000,
      # so we can construct a rollout whose second bucket just barely contains that value
      bucket_value = (subject.bucket_user(user, flag_key, "key", salt, nil) * 100000).truncate()
      expect(bucket_value).to be > 0
      expect(bucket_value).to be < 100000

      bad_variation_a = 0
      matched_variation = 1
      bad_variation_b = 2
      rule = {
        rollout: {
          variations: [
            { variation: bad_variation_a, weight: bucket_value }, # end of bucket range is not inclusive, so it will *not* match the target value
            { variation: matched_variation, weight: 1 }, # size of this bucket is 1, so it only matches that specific value
            { variation: bad_variation_b, weight: 100000 - (bucket_value + 1) }
          ]
        }
      }
      flag = { key: flag_key, salt: salt }

      result_variation, _ = subject.variation_index_for_user(flag, rule, user)
      expect(result_variation).to be matched_variation
    end

    it "uses last bucket if bucket value is equal to total weight" do
      user = { key: "userkey" }
      flag_key = "flagkey"
      salt = "salt"

      bucket_value = (subject.bucket_user(user, flag_key, "key", salt, nil) * 100000).truncate()

      # We'll construct a list of variations that stops right at the target bucket value
      rule = {
        rollout: {
          variations: [
            { variation: 0, weight: bucket_value }
          ]
        }
      }
      flag = { key: flag_key, salt: salt }

      result_variation, _ = subject.variation_index_for_user(flag, rule, user)
      expect(result_variation).to be 0
    end
  end
end
