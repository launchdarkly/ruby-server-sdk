require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    evaluator_tests_with_and_without_preprocessing "Evaluator (rules)" do |desc, factory|
      describe "#{desc} - evaluate", :evaluator_spec_base => true do
        it "matches user from rules" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 1 }
          flag = factory.boolean_flag_with_rules([rule])
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        if factory.with_preprocessing
          it "reuses rule match result detail instances" do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 1 }
            flag = factory.boolean_flag_with_rules([rule])
            user = { key: 'userkey' }
            detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
            result1 = basic_evaluator.evaluate(flag, user)
            result2 = basic_evaluator.evaluate(flag, user)
            expect(result1.detail.reason.rule_id).to eq 'ruleid'
            expect(result1.detail).to be result2.detail
          end
        end

        it "returns an error if rule variation is too high" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 999 }
          flag = factory.boolean_flag_with_rules([rule])
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if rule variation is negative" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: -1 }
          flag = factory.boolean_flag_with_rules([rule])
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if rule has neither variation nor rollout" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }] }
          flag = factory.boolean_flag_with_rules([rule])
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
          flag = factory.boolean_flag_with_rules([rule])
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "coerces user key to a string for evaluation" do
          clause = { attribute: 'key', op: 'in', values: ['999'] }
          flag = factory.boolean_flag_with_clauses([clause])
          user = { key: 999 }
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail.value).to eq(true)
        end

        it "coerces secondary key to a string for evaluation" do
          # We can't really verify that the rollout calculation works correctly, but we can at least
          # make sure it doesn't error out if there's a non-string secondary value (ch35189)
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
            rollout: { salt: '', variations: [ { weight: 100000, variation: 1 } ] } }
          flag = factory.boolean_flag_with_rules([rule])
          user = { key: "userkey", secondary: 999 }
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail.reason).to eq(EvaluationReason::rule_match(0, 'ruleid'))
        end

        describe "rule experiment/rollout behavior" do
          it "evaluates rollout for rule" do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
              rollout: { variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
            flag = factory.boolean_flag_with_rules([rule])
            user = { key: 'userkey' }
            detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
            result = basic_evaluator.evaluate(flag, user)
            expect(result.detail).to eq(detail)
            expect(result.prereq_evals).to eq(nil)
          end

          if factory.with_preprocessing
            it "reuses rule rollout result detail instance" do
              rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
                rollout: { variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
              flag = factory.boolean_flag_with_rules([rule])
              user = { key: 'userkey' }
              detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
              result1 = basic_evaluator.evaluate(flag, user)
              result2 = basic_evaluator.evaluate(flag, user)
              expect(result1.detail).to eq(detail)
              expect(result2.detail).to be(result1.detail)
            end
          end

          it "sets the in_experiment value if rollout kind is experiment " do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
              rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
            flag = factory.boolean_flag_with_rules([rule])
            user = { key: "userkey", secondary: 999 }
            result = basic_evaluator.evaluate(flag, user)
            expect(result.detail.reason.to_json).to include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(true)
          end

          it "does not set the in_experiment value if rollout kind is not experiment " do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
              rollout: { kind: 'rollout', variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
            flag = factory.boolean_flag_with_rules([rule])
            user = { key: "userkey", secondary: 999 }
            result = basic_evaluator.evaluate(flag, user)
            expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(nil)
          end

          it "does not set the in_experiment value if rollout kind is experiment and untracked is true" do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
              rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: true } ] } }
            flag = factory.boolean_flag_with_rules([rule])
            user = { key: "userkey", secondary: 999 }
            result = basic_evaluator.evaluate(flag, user)
            expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(nil)
          end
        end
      end
    end
  end
end
