require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    evaluator_tests_with_and_without_preprocessing "Evaluator (clauses)" do |desc, factory|
      describe "#{desc} - evaluate", :evaluator_spec_base => true do
        it "can match built-in attribute" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause = { attribute: 'name', op: 'in', values: ['Bob'] }
          flag = factory.boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be true
        end

        it "can match custom attribute" do
          context = LDContext.create({ key: 'x', name: 'Bob', custom: { legs: 4 } })
          clause = { attribute: 'legs', op: 'in', values: [4] }
          flag = factory.boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be true
        end

        it "returns false for missing attribute" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause = { attribute: 'legs', op: 'in', values: [4] }
          flag = factory.boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be false
        end

        it "returns false for unknown operator" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause = { attribute: 'name', op: 'unknown', values: [4] }
          flag = factory.boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be false
        end

        it "does not stop evaluating rules after clause with unknown operator" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause0 = { attribute: 'name', op: 'unknown', values: [4] }
          rule0 = { clauses: [ clause0 ], variation: 1 }
          clause1 = { attribute: 'name', op: 'in', values: ['Bob'] }
          rule1 = { clauses: [ clause1 ], variation: 1 }
          flag = factory.boolean_flag_with_rules([rule0, rule1])
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be true
        end

        it "can be negated" do
          context = LDContext.create({ key: 'x', name: 'Bob' })
          clause = { attribute: 'name', op: 'in', values: ['Bob'], negate: true }
          flag = factory.boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, context).detail.value).to be false
        end
      end
    end
  end
end
