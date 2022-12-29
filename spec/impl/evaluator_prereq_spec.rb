require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    describe "evaluate", :evaluator_spec_base => true do
      it "returns off variation if prerequisite is not found" do
        flag = Flags.from_hash(
          {
            key: 'feature0',
            on: true,
            prerequisites: [{ key: 'badfeature', variation: 1 }],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: %w[a b c],
          }
        )
        context = LDContext.create({ key: 'x' })
        detail = EvaluationDetail.new('b', 1, EvaluationReason::prerequisite_failed('badfeature'))
        e = EvaluatorBuilder.new(logger).with_unknown_flag('badfeature').build
        result = e.evaluate(flag, context)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(nil)
      end

      it "reuses prerequisite-failed result detail instances" do
        flag = Flags.from_hash(
          {
            key: 'feature0',
            on: true,
            prerequisites: [{ key: 'badfeature', variation: 1 }],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: %w[a b c],
          }
        )
        context = LDContext.create({ key: 'x' })
        e = EvaluatorBuilder.new(logger).with_unknown_flag('badfeature').build
        result1 = e.evaluate(flag, context)
        expect(result1.detail.reason).to eq EvaluationReason::prerequisite_failed('badfeature')
        result2 = e.evaluate(flag, context)
        expect(result2.detail).to be result1.detail
      end

      it "returns off variation and event if prerequisite of a prerequisite is not found" do
        flag = Flags.from_hash(
          {
            key: 'feature0',
            on: true,
            prerequisites: [{ key: 'feature1', variation: 1 }],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: %w[a b c],
            version: 1,
          }
        )
        flag1 = Flags.from_hash(
          {
            key: 'feature1',
            on: true,
            prerequisites: [{ key: 'feature2', variation: 1 }], # feature2 doesn't exist
            fallthrough: { variation: 0 },
            variations: %w[d e],
            version: 2,
          }
        )
        context = LDContext.create({ key: 'x' })
        detail = EvaluationDetail.new('b', 1, EvaluationReason::prerequisite_failed('feature1'))
        expected_prereqs = [
          PrerequisiteEvalRecord.new(flag1, flag, EvaluationDetail.new(nil, nil, EvaluationReason::prerequisite_failed('feature2'))),
        ]
        e = EvaluatorBuilder.new(logger).with_flag(flag1).with_unknown_flag('feature2').build
        result = e.evaluate(flag, context)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(expected_prereqs)
      end

      it "returns off variation and event if prerequisite is off" do
        flag = Flags.from_hash(
          {
            key: 'feature0',
            on: true,
            prerequisites: [{ key: 'feature1', variation: 1 }],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: %w[a b c],
            version: 1,
          }
        )
        flag1 = Flags.from_hash(
          {
            key: 'feature1',
            on: false,
            # note that even though it returns the desired variation, it is still off and therefore not a match
            offVariation: 1,
            fallthrough: { variation: 0 },
            variations: %w[d e],
            version: 2,
          }
        )
        context = LDContext.create({ key: 'x' })
        detail = EvaluationDetail.new('b', 1, EvaluationReason::prerequisite_failed('feature1'))
        expected_prereqs = [
          PrerequisiteEvalRecord.new(flag1, flag, EvaluationDetail.new('e', 1, EvaluationReason::off)),
        ]
        e = EvaluatorBuilder.new(logger).with_flag(flag1).build
        result = e.evaluate(flag, context)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(expected_prereqs)
      end

      it "returns off variation and event if prerequisite is not met" do
        flag = Flags.from_hash(
          {
            key: 'feature0',
            on: true,
            prerequisites: [{ key: 'feature1', variation: 1 }],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: %w[a b c],
            version: 1,
          }
        )
        flag1 = Flags.from_hash(
          {
            key: 'feature1',
            on: true,
            fallthrough: { variation: 0 },
            variations: %w[d e],
            version: 2,
          }
        )
        context = LDContext.create({ key: 'x' })
        detail = EvaluationDetail.new('b', 1, EvaluationReason::prerequisite_failed('feature1'))
        expected_prereqs = [
          PrerequisiteEvalRecord.new(flag1, flag, EvaluationDetail.new('d', 0, EvaluationReason::fallthrough)),
        ]
        e = EvaluatorBuilder.new(logger).with_flag(flag1).build
        result = e.evaluate(flag, context)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(expected_prereqs)
      end

      it "returns fallthrough variation and event if prerequisite is met and there are no rules" do
        flag = Flags.from_hash(
          {
            key: 'feature0',
            on: true,
            prerequisites: [{ key: 'feature1', variation: 1 }],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: %w[a b c],
            version: 1,
          }
        )
        flag1 = Flags.from_hash(
          {
            key: 'feature1',
            on: true,
            fallthrough: { variation: 1 },
            variations: %w[d e],
            version: 2,
          }
        )
        context = LDContext.create({ key: 'x' })
        detail = EvaluationDetail.new('a', 0, EvaluationReason::fallthrough)
        expected_prereqs = [
          PrerequisiteEvalRecord.new(flag1, flag, EvaluationDetail.new('e', 1, EvaluationReason::fallthrough)),
        ]
        e = EvaluatorBuilder.new(logger).with_flag(flag1).build
        result = e.evaluate(flag, context)
        expect(result.detail).to eq(detail)
        expect(result.prereq_evals).to eq(expected_prereqs)
      end

      (1..4).each do |depth|
        it "correctly detects cycles are at a depth of #{depth}" do
          flags = []
          (0...depth).each do |i|
            flags << Flags.from_hash(
              {
                key: "flagkey#{i}",
                on: true,
                offVariation: 0,
                prerequisites: [{ key: "flagkey#{(i + 1) % depth}", variation: 0 }],
                variations: [false, true],
              }
            )
          end

          builder = EvaluatorBuilder.new(logger)
          flags.each { |flag| builder.with_flag(flag) }

          evaluator = builder.build
          result = evaluator.evaluate(flags[0], LDContext.with_key('user'))
          reason = EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG)
          expect(result.detail.reason).to eq(reason)
        end
      end
    end
  end
end
