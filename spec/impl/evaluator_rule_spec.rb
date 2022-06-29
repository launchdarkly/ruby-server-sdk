require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    describe "Evaluator (rules)", :evaluator_spec_base => true do
      subject { Evaluator }

      it "matches user from rules" do
        rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 1 }
        flag = boolean_flag_with_rules([rule])
        user = { key: 'userkey' }
        detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
        result = basic_evaluator.evaluate(flag, user)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(nil)
      end

      it "reuses rule match reason instances if possible" do
        rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 1 }
        flag = boolean_flag_with_rules([rule])
        Model.postprocess_item_after_deserializing!(FEATURES, flag)  # now there's a cached rule match reason
        user = { key: 'userkey' }
        detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
        result1 = basic_evaluator.evaluate(flag, user)
        result2 = basic_evaluator.evaluate(flag, user)
        expect(result1.detail.reason.rule_id).to eq 'ruleid'
        expect(result1.detail.reason).to be result2.detail.reason
      end

      it "returns an error if rule variation is too high" do
        rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 999 }
        flag = boolean_flag_with_rules([rule])
        user = { key: 'userkey' }
        detail = EvaluationDetail.new(nil, nil,
          EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
        result = basic_evaluator.evaluate(flag, user)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(nil)
      end

      it "returns an error if rule variation is negative" do
        rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: -1 }
        flag = boolean_flag_with_rules([rule])
        user = { key: 'userkey' }
        detail = EvaluationDetail.new(nil, nil,
          EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
        result = basic_evaluator.evaluate(flag, user)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(nil)
      end

      it "returns an error if rule has neither variation nor rollout" do
        rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }] }
        flag = boolean_flag_with_rules([rule])
        user = { key: 'userkey' }
        detail = EvaluationDetail.new(nil, nil,
          EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
        result = basic_evaluator.evaluate(flag, user)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(nil)
      end

      it "returns an error if rule has a rollout with no variations" do
        rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
          rollout: { variations: [] } }
        flag = boolean_flag_with_rules([rule])
        user = { key: 'userkey' }
        detail = EvaluationDetail.new(nil, nil,
          EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
        result = basic_evaluator.evaluate(flag, user)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(nil)
      end

      it "coerces user key to a string for evaluation" do
        clause = { attribute: 'key', op: 'in', values: ['999'] }
        flag = boolean_flag_with_clauses([clause])
        user = { key: 999 }
        result = basic_evaluator.evaluate(flag, user)
        expect(result.detail.value).to eq(true)
      end

      it "coerces secondary key to a string for evaluation" do
        # We can't really verify that the rollout calculation works correctly, but we can at least
        # make sure it doesn't error out if there's a non-string secondary value (ch35189)
        rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
          rollout: { salt: '', variations: [ { weight: 100000, variation: 1 } ] } }
        flag = boolean_flag_with_rules([rule])
        user = { key: "userkey", secondary: 999 }
        result = basic_evaluator.evaluate(flag, user)
        expect(result.detail.reason).to eq(EvaluationReason::rule_match(0, 'ruleid'))
      end

      describe "experiment rollout behavior" do
        it "sets the in_experiment value if rollout kind is experiment " do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
            rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
          flag = boolean_flag_with_rules([rule])
          user = { key: "userkey", secondary: 999 }
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail.reason.to_json).to include('"inExperiment":true')
          expect(result.detail.reason.in_experiment).to eq(true)
        end

        it "does not set the in_experiment value if rollout kind is not experiment " do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
            rollout: { kind: 'rollout', variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
          flag = boolean_flag_with_rules([rule])
          user = { key: "userkey", secondary: 999 }
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
          expect(result.detail.reason.in_experiment).to eq(nil)
        end

        it "does not set the in_experiment value if rollout kind is experiment and untracked is true" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
            rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: true } ] } }
          flag = boolean_flag_with_rules([rule])
          user = { key: "userkey", secondary: 999 }
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
          expect(result.detail.reason.in_experiment).to eq(nil)
        end
      end
    end
  end
end
