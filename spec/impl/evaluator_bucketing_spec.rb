require "spec_helper"

describe LaunchDarkly::Impl::EvaluatorBucketing do
  subject { LaunchDarkly::Impl::EvaluatorBucketing }

  describe "bucket_user" do
    describe "seed exists" do
      let(:seed) { 61 }
      it "returns the expected bucket values for seed" do
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

      it "returns the same bucket regardless of hashKey and salt" do
        user = { key: "userKeyA" }
        bucket1 = subject.bucket_user(user, "hashKey", "key", "saltyA", seed)
        bucket2 = subject.bucket_user(user, "hashKey1", "key", "saltyB", seed)
        bucket3 = subject.bucket_user(user, "hashKey2", "key", "saltyC", seed)
        expect(bucket1).to eq(bucket2)
        expect(bucket2).to eq(bucket3)
      end

      it "returns a different bucket if the seed is not the same" do
        user = { key: "userKeyA" }
        bucket1 = subject.bucket_user(user, "hashKey", "key", "saltyA", seed)
        bucket2 = subject.bucket_user(user, "hashKey1", "key", "saltyB", seed+1)
        expect(bucket1).to_not eq(bucket2)
      end

      it "returns a different bucket if the user is not the same" do
        user1 = { key: "userKeyA" }
        user2 = { key: "userKeyB" }
        bucket1 = subject.bucket_user(user1, "hashKey", "key", "saltyA", seed)
        bucket2 = subject.bucket_user(user2, "hashKey1", "key", "saltyB", seed)
        expect(bucket1).to_not eq(bucket2)
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
          intAttr: 33333,
        },
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
          floatAttr: 33.5,
        },
      }
      result = subject.bucket_user(user, "hashKey", "floatAttr", "saltyA", nil)
      expect(result).to eq(0.0)
    end


    it "cannot bucket by bool value" do
      user = {
        key: "userkey",
        custom: {
          boolAttr: true,
        },
      }
      result = subject.bucket_user(user, "hashKey", "boolAttr", "saltyA", nil)
      expect(result).to eq(0.0)
    end
  end

  describe "variation_index_for_user" do
    context "rollout is not an experiment" do
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
              { variation: bad_variation_b, weight: 100000 - (bucket_value + 1) },
            ],
          },
        }
        flag = { key: flag_key, salt: salt }

        result_variation, inExperiment = subject.variation_index_for_user(flag, rule, user)
        expect(result_variation).to be matched_variation
        expect(inExperiment).to be(false)
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
              { variation: 0, weight: bucket_value },
            ],
          },
        }
        flag = { key: flag_key, salt: salt }

        result_variation, inExperiment = subject.variation_index_for_user(flag, rule, user)
        expect(result_variation).to be 0
        expect(inExperiment).to be(false)
      end
    end
  end

  context "rollout is an experiment" do
    it "returns whether user is in the experiment or not" do
      user1 = { key: "userKeyA" }
      user2 = { key: "userKeyB" }
      user3 = { key: "userKeyC" }
      flag_key = "flagkey"
      salt = "salt"
      seed = 61


      rule = {
        rollout: {
          seed: seed,
          kind: 'experiment',
          variations: [
            { variation: 0, weight: 10000, untracked: false },
            { variation: 2, weight: 20000, untracked: false },
            { variation: 0, weight: 70000 , untracked: true },
          ],
        },
      }
      flag = { key: flag_key, salt: salt }

      result_variation, inExperiment = subject.variation_index_for_user(flag, rule, user1)
      expect(result_variation).to be(0)
      expect(inExperiment).to be(true)
      result_variation, inExperiment = subject.variation_index_for_user(flag, rule, user2)
      expect(result_variation).to be(2)
      expect(inExperiment).to be(true)
      result_variation, inExperiment = subject.variation_index_for_user(flag, rule, user3)
      expect(result_variation).to be(0)
      expect(inExperiment).to be(false)
    end

    it "uses last bucket if bucket value is equal to total weight" do
      user = { key: "userkey" }
      flag_key = "flagkey"
      salt = "salt"
      seed = 61

      bucket_value = (subject.bucket_user(user, flag_key, "key", salt, seed) * 100000).truncate()

      # We'll construct a list of variations that stops right at the target bucket value
      rule = {
        rollout: {
          seed: seed,
          kind: 'experiment',
          variations: [
            { variation: 0, weight: bucket_value, untracked: false },
          ],
        },
      }
      flag = { key: flag_key, salt: salt }

      result_variation, inExperiment = subject.variation_index_for_user(flag, rule, user)
      expect(result_variation).to be 0
      expect(inExperiment).to be(true)
    end
  end
end
