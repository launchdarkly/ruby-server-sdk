require "events_test_util"
require "model_builders"
require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    describe "Evaluator (general)" do
      describe "evaluate", :evaluator_spec_base => true do
        it "returns off variation if flag is off" do
          flag = Flags.from_hash({
            key: 'feature',
            on: false,
            offVariation: 1,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'x' })
          detail = EvaluationDetail.new('b', 1, EvaluationReason::off)
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns nil if flag is off and off variation is unspecified" do
          flag = Flags.from_hash({
            key: 'feature',
            on: false,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'x' })
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::off)
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "reuses off result detail instance" do
          flag = Flags.from_hash({
            key: 'feature',
            on: false,
            offVariation: 1,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'x' })
          detail = EvaluationDetail.new('b', 1, EvaluationReason::off)
          result1 = basic_evaluator.evaluate(flag, context)
          result2 = basic_evaluator.evaluate(flag, context)
          expect(result1.detail).to eq(detail)
          expect(result2.detail).to be(result1.detail)
        end

        it "returns an error if off variation is too high" do
          flag = Flags.from_hash({
            key: 'feature',
            on: false,
            offVariation: 999,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'x' })
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if off variation is negative" do
          flag = Flags.from_hash({
            key: 'feature',
            on: false,
            offVariation: -1,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'x' })
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns fallthrough variation if flag is on and no rules match" do
          flag = Flags.from_hash({
            key: 'feature0',
            on: true,
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1,
            rules: [
              { variation: 2, clauses: [ { attribute: "key", op: "in", values: ["zzz"] } ] },
            ],
          })
          context = LDContext.create({ key: 'x' })
          detail = EvaluationDetail.new('a', 0, EvaluationReason::fallthrough)
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "reuses fallthrough variation result detail instance" do
          flag = Flags.from_hash({
            key: 'feature0',
            on: true,
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1,
            rules: [
              { variation: 2, clauses: [ { attribute: "key", op: "in", values: ["zzz"] } ] },
            ],
          })
          context = LDContext.create({ key: 'x' })
          detail = EvaluationDetail.new('a', 0, EvaluationReason::fallthrough)
          result1 = basic_evaluator.evaluate(flag, context)
          result2 = basic_evaluator.evaluate(flag, context)
          expect(result1.detail).to eq(detail)
          expect(result2.detail).to be(result1.detail)
        end

        it "returns an error if fallthrough variation is too high" do
          flag = Flags.from_hash({
            key: 'feature',
            on: true,
            fallthrough: { variation: 999 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if fallthrough variation is negative" do
          flag = Flags.from_hash({
            key: 'feature',
            on: true,
            fallthrough: { variation: -1 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if fallthrough has no variation or rollout" do
          flag = Flags.from_hash({
            key: 'feature',
            on: true,
            fallthrough: { },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if fallthrough has a rollout with no variations" do
          flag = Flags.from_hash({
            key: 'feature',
            on: true,
            fallthrough: { rollout: { variations: [] } },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "matches context from targets" do
          flag = Flags.from_hash({
            key: 'feature',
            on: true,
            targets: [
              { values: [ 'whoever', 'userkey' ], variation: 2 },
            ],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new('c', 2, EvaluationReason::target_match)
          result = basic_evaluator.evaluate(flag, context)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "reuses target-match result detail instances" do
          flag = Flags.from_hash({
            key: 'feature',
            on: true,
            targets: [
              { values: [ 'whoever', 'userkey' ], variation: 2 },
            ],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
          })
          context = LDContext.create({ key: 'userkey' })
          detail = EvaluationDetail.new('c', 2, EvaluationReason::target_match)
          result1 = basic_evaluator.evaluate(flag, context)
          result2 = basic_evaluator.evaluate(flag, context)
          expect(result1.detail).to eq(detail)
          expect(result2.detail).to be(result1.detail)
        end

        describe "fallthrough experiment/rollout behavior" do
          it "evaluates rollout for fallthrough" do
            flag = Flags.from_hash({
              key: 'feature0',
              on: true,
              fallthrough: { rollout: { variations: [ { weight: 100000, variation: 1, untracked: false } ] } },
              offVariation: 1,
              variations: ['a', 'b', 'c'],
              version: 1,
            })
            context = LDContext.create({ key: 'x' })
            detail = EvaluationDetail.new('b', 1, EvaluationReason::fallthrough)
            result = basic_evaluator.evaluate(flag, context)
            expect(result.detail).to eq(detail)
            expect(result.prereq_evals).to eq(nil)
          end

          it "reuses fallthrough rollout result detail instance" do
            flag = Flags.from_hash({
              key: 'feature0',
              on: true,
              fallthrough: { rollout: { variations: [ { weight: 100000, variation: 1, untracked: false } ] } },
              offVariation: 1,
              variations: ['a', 'b', 'c'],
              version: 1,
            })
            context = LDContext.create({ key: 'x' })
            detail = EvaluationDetail.new('b', 1, EvaluationReason::fallthrough)
            result1 = basic_evaluator.evaluate(flag, context)
            result2 = basic_evaluator.evaluate(flag, context)
            expect(result1.detail).to eq(detail)
            expect(result2.detail).to be(result1.detail)
          end

          it "sets the in_experiment value if rollout kind is experiment and untracked false" do
            flag = Flags.from_hash({
              key: 'feature',
              on: true,
              fallthrough: { rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: false } ] } },
              offVariation: 1,
              variations: ['a', 'b', 'c'],
            })
            context = LDContext.create({ key: 'userkey' })
            result = basic_evaluator.evaluate(flag, context)
            expect(result.detail.reason.to_json).to include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(true)
          end

          it "does not set the in_experiment value if rollout kind is not experiment" do
            flag = Flags.from_hash({
              key: 'feature',
              on: true,
              fallthrough: { rollout: { kind: 'rollout', variations: [ { weight: 100000, variation: 1, untracked: false } ] } },
              offVariation: 1,
              variations: ['a', 'b', 'c'],
            })
            context = LDContext.create({ key: 'userkey' })
            result = basic_evaluator.evaluate(flag, context)
            expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(nil)
          end

          it "does not set the in_experiment value if rollout kind is experiment and untracked is true" do
            flag = Flags.from_hash({
              key: 'feature',
              on: true,
              fallthrough: { rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: true } ] } },
              offVariation: 1,
              variations: ['a', 'b', 'c'],
            })
            context = LDContext.create({ key: 'userkey' })
            result = basic_evaluator.evaluate(flag, context)
            expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(nil)
          end
        end
      end
    end
  end
end
