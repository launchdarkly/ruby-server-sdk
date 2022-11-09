require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    describe "Evaluator (rules)" do
      describe "evaluate", :evaluator_spec_base => true do
        it "matches context from rules" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 1 }
          flag = Flags.boolean_flag_with_rules(rule)
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "reuses rule match result detail instances" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 1 }
          flag = Flags.boolean_flag_with_rules(rule)
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
          result1 = basic_evaluator.evaluate(flag, context)
          result2 = basic_evaluator.evaluate(flag, context)
          expect(result1.detail.reason.rule_id).to eq 'ruleid'
          expect(result1.detail).to be result2.detail
        end

        it "returns an error if rule variation is too high" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 999 }
          flag = Flags.boolean_flag_with_rules(rule)
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if rule variation is negative" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: -1 }
          flag = Flags.boolean_flag_with_rules(rule)
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if rule has neither variation nor rollout" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }] }
          flag = Flags.boolean_flag_with_rules(rule)
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if rule has a rollout with no variations" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
            rollout: { variations: [] } }
          flag = Flags.boolean_flag_with_rules(rule)
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "coerces context key to a string for evaluation" do
          clause = { attribute: 'key', op: 'in', values: ['999'] }
          flag = Flags.boolean_flag_with_clauses(clause)
          context = LDContext.create({ key: 999 })
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail.value).to eq(true)
        end

        describe "rule experiment/rollout behavior" do
          it "evaluates rollout for rule" do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
              rollout: { variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
            flag = Flags.boolean_flag_with_rules(rule)
            context = LDContext.create({ key: 'userkey' })
            detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
            result = basic_evaluator.evaluate(flag, context)
            expect(result.detail).to eq(detail)
            expect(result.prereq_evals).to eq(nil)
          end

          it "reuses rule rollout result detail instance" do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
              rollout: { variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
            flag = Flags.boolean_flag_with_rules(rule)
            context = LDContext.create({ key: 'userkey' })
            detail = EvaluationDetail.new(true, 1, EvaluationReason::rule_match(0, 'ruleid'))
            result1 = basic_evaluator.evaluate(flag, context)
            result2 = basic_evaluator.evaluate(flag, context)
            expect(result1.detail).to eq(detail)
            expect(result2.detail).to be(result1.detail)
          end

          it "sets the in_experiment value if rollout kind is experiment " do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
              rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
            flag = Flags.boolean_flag_with_rules(rule)
            context = LDContext.create({ key: "userkey" })
            result = basic_evaluator.evaluate(flag, context)
            expect(result.detail.reason.to_json).to include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(true)
          end

          it "does not set the in_experiment value if rollout kind is not experiment " do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
              rollout: { kind: 'rollout', variations: [ { weight: 100000, variation: 1, untracked: false } ] } }
            flag = Flags.boolean_flag_with_rules(rule)
            context = LDContext.create({ key: "userkey" })
            result = basic_evaluator.evaluate(flag, context)
            expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(nil)
          end

          it "does not set the in_experiment value if rollout kind is experiment and untracked is true" do
            rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
              rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: true } ] } }
            flag = Flags.boolean_flag_with_rules(rule)
            context = LDContext.create({ key: "userkey" })
            result = basic_evaluator.evaluate(flag, context)
            expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(nil)
          end
        end
      end
    end
  end
end
