require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    describe "Evaluator (clauses)" do
      describe "evaluate", :evaluator_spec_base => true do
        it "can match built-in attribute" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause = { attribute: 'name', op: 'in', values: ['Bob'] }
          flag = Flags.boolean_flag_with_clauses(clause)
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be true
        end

        it "can match custom attribute" do
          context = LDContext.create({ key: 'x', name: 'Bob', custom: { legs: 4 } })
          clause = { attribute: 'legs', op: 'in', values: [4] }
          flag = Flags.boolean_flag_with_clauses(clause)
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be true
        end

        it "returns false for missing attribute" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause = { attribute: 'legs', op: 'in', values: [4] }
          flag = Flags.boolean_flag_with_clauses(clause)
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be false
        end

        it "returns false for unknown operator" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause = { attribute: 'name', op: 'unknown', values: [4] }
          flag = Flags.boolean_flag_with_clauses(clause)
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be false
        end

        it "does not stop evaluating rules after clause with unknown operator" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause0 = { attribute: 'name', op: 'unknown', values: [4] }
          rule0 = { clauses: [ clause0 ], variation: 1 }
          clause1 = { attribute: 'name', op: 'in', values: ['Bob'] }
          rule1 = { clauses: [ clause1 ], variation: 1 }
          flag = Flags.boolean_flag_with_rules(rule0, rule1)
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be true
        end

        it "can be negated" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause = { attribute: 'name', op: 'in', values: ['Bob'], negate: true }
          flag = Flags.boolean_flag_with_clauses(clause)
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be false
        end

        it "clause match uses context kind" do
          clause = { contextKind: 'company', attribute: 'name', op: 'in', values: ['Catco'] }

          context1 = LDContext.create({ key: 'cc', kind: 'company', name: 'Catco'})
          context2 = LDContext.create({ key: 'l', kind: 'user', name: 'Lucy' })
          context3 = LDContext.create_multi([context1, context2])

          flag = Flags.boolean_flag_with_clauses(clause)

          expect(basic_evaluator.evaluate(flag, context1).detail.value).to be true
          expect(basic_evaluator.evaluate(flag, context2).detail.value).to be false
          expect(basic_evaluator.evaluate(flag, context3).detail.value).to be true
        end

        it "clause match by kind attribute" do
          clause = { attribute: 'kind', op: 'startsWith', values: ['a'] }

          context1 = LDContext.create({ key: 'key' })
          context2 = LDContext.create({ key: 'key', kind: 'ab' })
          context3 = LDContext.create_multi(
            [
              LDContext.create({ key: 'key', kind: 'cd' }),
              LDContext.create({ key: 'key', kind: 'ab' }),
            ]
          )

          flag = Flags.boolean_flag_with_clauses(clause)

          expect(basic_evaluator.evaluate(flag, context1).detail.value).to be false
          expect(basic_evaluator.evaluate(flag, context2).detail.value).to be true
          expect(basic_evaluator.evaluate(flag, context3).detail.value).to be true
        end
      end
    end
  end
end
