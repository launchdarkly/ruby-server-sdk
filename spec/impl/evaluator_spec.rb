require "events_test_util"
require "model_builders"
require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    evaluator_tests_with_and_without_preprocessing "Evaluator (general)" do |desc, factory|
      describe "#{desc} - evaluate", :evaluator_spec_base => true do
        it "returns off variation if flag is off" do
          flag = factory.flag({
            key: 'feature',
            on: false,
            offVariation: 1,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c']
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1, EvaluationReason::off)
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns nil if flag is off and off variation is unspecified" do
          flag = factory.flag({
            key: 'feature',
            on: false,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c']
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::off)
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        if factory.with_preprocessing
          it "reuses off result detail instance" do
            flag = factory.flag({
              key: 'feature',
              on: false,
              offVariation: 1,
              fallthrough: { variation: 0 },
              variations: ['a', 'b', 'c']
            })
            user = { key: 'x' }
            detail = EvaluationDetail.new('b', 1, EvaluationReason::off)
            result1 = basic_evaluator.evaluate(flag, user)
            result2 = basic_evaluator.evaluate(flag, user)
            expect(result1.detail).to eq(detail)
            expect(result2.detail).to be(result1.detail)
          end
        end

        it "returns an error if off variation is too high" do
          flag = factory.flag({
            key: 'feature',
            on: false,
            offVariation: 999,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c']
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if off variation is negative" do
          flag = factory.flag({
            key: 'feature',
            on: false,
            offVariation: -1,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c']
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new(nil, nil,
            EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns off variation if prerequisite is not found" do
          flag = factory.flag({
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'badfeature', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1, EvaluationReason::prerequisite_failed('badfeature'))
          e = EvaluatorBuilder.new(logger).with_unknown_flag('badfeature').build
          result = e.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        if factory.with_preprocessing
          it "reuses prerequisite-failed result detail instances" do
            flag = factory.flag({
              key: 'feature0',
              on: true,
              prerequisites: [{key: 'badfeature', variation: 1}],
              fallthrough: { variation: 0 },
              offVariation: 1,
              variations: ['a', 'b', 'c']
            })
            user = { key: 'x' }
            e = EvaluatorBuilder.new(logger).with_unknown_flag('badfeature').build
            result1 = e.evaluate(flag, user)
            expect(result1.detail.reason).to eq EvaluationReason::prerequisite_failed('badfeature')
            result2 = e.evaluate(flag, user)
            expect(result2.detail).to be result1.detail
          end
        end

        it "returns off variation and event if prerequisite of a prerequisite is not found" do
          flag = factory.flag({
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'feature1', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1
          })
          flag1 = factory.flag({
            key: 'feature1',
            on: true,
            prerequisites: [{key: 'feature2', variation: 1}], # feature2 doesn't exist
            fallthrough: { variation: 0 },
            variations: ['d', 'e'],
            version: 2
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1, EvaluationReason::prerequisite_failed('feature1'))
          expected_prereqs = [
            PrerequisiteEvalRecord.new(flag1, flag, EvaluationDetail.new(nil, nil, EvaluationReason::prerequisite_failed('feature2')))
          ]
          e = EvaluatorBuilder.new(logger).with_flag(flag1).with_unknown_flag('feature2').build
          result = e.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(expected_prereqs)
        end

        it "returns off variation and event if prerequisite is off" do
          flag = factory.flag({
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'feature1', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1
          })
          flag1 = factory.flag({
            key: 'feature1',
            on: false,
            # note that even though it returns the desired variation, it is still off and therefore not a match
            offVariation: 1,
            fallthrough: { variation: 0 },
            variations: ['d', 'e'],
            version: 2
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1, EvaluationReason::prerequisite_failed('feature1'))
          expected_prereqs = [
            PrerequisiteEvalRecord.new(flag1, flag, EvaluationDetail.new('e', 1, EvaluationReason::off))
          ]
          e = EvaluatorBuilder.new(logger).with_flag(flag1).build
          result = e.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(expected_prereqs)
        end

        it "returns off variation and event if prerequisite is not met" do
          flag = factory.flag({
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'feature1', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1
          })
          flag1 = factory.flag({
            key: 'feature1',
            on: true,
            fallthrough: { variation: 0 },
            variations: ['d', 'e'],
            version: 2
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1, EvaluationReason::prerequisite_failed('feature1'))
          expected_prereqs = [
            PrerequisiteEvalRecord.new(flag1, flag, EvaluationDetail.new('d', 0, EvaluationReason::fallthrough))
          ]
          e = EvaluatorBuilder.new(logger).with_flag(flag1).build
          result = e.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(expected_prereqs)
        end

        it "returns fallthrough variation and event if prerequisite is met and there are no rules" do
          flag = factory.flag({
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'feature1', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1
          })
          flag1 = factory.flag({
            key: 'feature1',
            on: true,
            fallthrough: { variation: 1 },
            variations: ['d', 'e'],
            version: 2
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new('a', 0, EvaluationReason::fallthrough)
          expected_prereqs = [
            PrerequisiteEvalRecord.new(flag1, flag, EvaluationDetail.new('e', 1, EvaluationReason::fallthrough))
          ]
          e = EvaluatorBuilder.new(logger).with_flag(flag1).build
          result = e.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(expected_prereqs)
        end

        it "returns fallthrough variation if flag is on and no rules match" do
          flag = factory.flag({
            key: 'feature0',
            on: true,
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1,
            rules: [
              { variation: 2, clauses: [ { attribute: "key", op: "in", values: ["zzz"] } ] }
            ]
          })
          user = { key: 'x' }
          detail = EvaluationDetail.new('a', 0, EvaluationReason::fallthrough)
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        if factory.with_preprocessing
          it "reuses fallthrough variation result detail instance" do
            flag = factory.flag({
              key: 'feature0',
              on: true,
              fallthrough: { variation: 0 },
              offVariation: 1,
              variations: ['a', 'b', 'c'],
              version: 1,
              rules: [
                { variation: 2, clauses: [ { attribute: "key", op: "in", values: ["zzz"] } ] }
              ]
            })
            user = { key: 'x' }
            detail = EvaluationDetail.new('a', 0, EvaluationReason::fallthrough)
            result1 = basic_evaluator.evaluate(flag, user)
            result2 = basic_evaluator.evaluate(flag, user)
            expect(result1.detail).to eq(detail)
            expect(result2.detail).to be(result1.detail)
          end
        end

        it "returns an error if fallthrough variation is too high" do
          flag = factory.flag({
            key: 'feature',
            on: true,
            fallthrough: { variation: 999 },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          })
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if fallthrough variation is negative" do
          flag = factory.flag({
            key: 'feature',
            on: true,
            fallthrough: { variation: -1 },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          })
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if fallthrough has no variation or rollout" do
          flag = factory.flag({
            key: 'feature',
            on: true,
            fallthrough: { },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          })
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "returns an error if fallthrough has a rollout with no variations" do
          flag = factory.flag({
            key: 'feature',
            on: true,
            fallthrough: { rollout: { variations: [] } },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          })
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil, EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG))
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        it "matches user from targets" do
          flag = factory.flag({
            key: 'feature',
            on: true,
            targets: [
              { values: [ 'whoever', 'userkey' ], variation: 2 }
            ],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          })
          user = { key: 'userkey' }
          detail = EvaluationDetail.new('c', 2, EvaluationReason::target_match)
          result = basic_evaluator.evaluate(flag, user)
          expect(result.detail).to eq(detail)
          expect(result.prereq_evals).to eq(nil)
        end

        if factory.with_preprocessing
          it "reuses target-match result detail instances" do
            flag = factory.flag({
              key: 'feature',
              on: true,
              targets: [
                { values: [ 'whoever', 'userkey' ], variation: 2 }
              ],
              fallthrough: { variation: 0 },
              offVariation: 1,
              variations: ['a', 'b', 'c']
            })
            user = { key: 'userkey' }
            detail = EvaluationDetail.new('c', 2, EvaluationReason::target_match)
            result1 = basic_evaluator.evaluate(flag, user)
            result2 = basic_evaluator.evaluate(flag, user)
            expect(result1.detail).to eq(detail)
            expect(result2.detail).to be(result1.detail)
          end
        end

        describe "fallthrough experiment/rollout behavior" do
          it "evaluates rollout for fallthrough" do
            flag = factory.flag({
              key: 'feature0',
              on: true,
              fallthrough: { rollout: { variations: [ { weight: 100000, variation: 1, untracked: false } ]  } },
              offVariation: 1,
              variations: ['a', 'b', 'c'],
              version: 1
            })
            user = { key: 'x' }
            detail = EvaluationDetail.new('b', 1, EvaluationReason::fallthrough)
            result = basic_evaluator.evaluate(flag, user)
            expect(result.detail).to eq(detail)
            expect(result.prereq_evals).to eq(nil)
          end

          if factory.with_preprocessing
            it "reuses fallthrough rollout result detail instance" do
              flag = factory.flag({
                key: 'feature0',
                on: true,
                fallthrough: { rollout: { variations: [ { weight: 100000, variation: 1, untracked: false } ]  } },
                offVariation: 1,
                variations: ['a', 'b', 'c'],
                version: 1
              })
              user = { key: 'x' }
              detail = EvaluationDetail.new('b', 1, EvaluationReason::fallthrough)
              result1 = basic_evaluator.evaluate(flag, user)
              result2 = basic_evaluator.evaluate(flag, user)
              expect(result1.detail).to eq(detail)
              expect(result2.detail).to be(result1.detail)
            end
          end

          it "sets the in_experiment value if rollout kind is experiment and untracked false" do
            flag = factory.flag({
              key: 'feature',
              on: true,
              fallthrough: { rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: false } ]  } },
              offVariation: 1,
              variations: ['a', 'b', 'c']
            })
            user = { key: 'userkey' }
            result = basic_evaluator.evaluate(flag, user)
            expect(result.detail.reason.to_json).to include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(true)
          end

          it "does not set the in_experiment value if rollout kind is not experiment" do
            flag = factory.flag({
              key: 'feature',
              on: true,
              fallthrough: { rollout: { kind: 'rollout', variations: [ { weight: 100000, variation: 1, untracked: false } ]  } },
              offVariation: 1,
              variations: ['a', 'b', 'c']
            })
            user = { key: 'userkey' }
            result = basic_evaluator.evaluate(flag, user)
            expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(nil)
          end

          it "does not set the in_experiment value if rollout kind is experiment and untracked is true" do
            flag = factory.flag({
              key: 'feature',
              on: true,
              fallthrough: { rollout: { kind: 'experiment', variations: [ { weight: 100000, variation: 1, untracked: true } ]  } },
              offVariation: 1,
              variations: ['a', 'b', 'c']
            })
            user = { key: 'userkey' }
            result = basic_evaluator.evaluate(flag, user)
            expect(result.detail.reason.to_json).to_not include('"inExperiment":true')
            expect(result.detail.reason.in_experiment).to eq(nil)
          end
        end
      end
    end
  end
end
