require "spec_helper"

module LaunchDarkly
  module Impl
    describe "Evaluator" do
      subject { Evaluator }

      let(:factory) { EventFactory.new(false) }

      let(:user) {
        {
          key: "userkey",
          email: "test@example.com",
          name: "Bob"
        }
      }

      let(:logger) { ::Logger.new($stdout, level: ::Logger::FATAL) }

      def get_nothing
        lambda { |key| raise "should not have requested #{key}" }
      end

      def get_things(map)
        lambda { |key|
          raise "should not have requested #{key}" if !map.has_key?(key)
          map[key]
        }
      end

      def basic_evaluator
        subject.new(get_nothing, get_nothing, logger)
      end

      def boolean_flag_with_rules(rules)
        { key: 'feature', on: true, rules: rules, fallthrough: { variation: 0 }, variations: [ false, true ] }
      end

      def boolean_flag_with_clauses(clauses)
        boolean_flag_with_rules([{ id: 'ruleid', clauses: clauses, variation: 1 }])
      end

      describe "evaluate" do
        it "returns off variation if flag is off" do
          flag = {
            key: 'feature',
            on: false,
            offVariation: 1,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c']
          }
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1, { kind: 'OFF' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns nil if flag is off and off variation is unspecified" do
          flag = {
            key: 'feature',
            on: false,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c']
          }
          user = { key: 'x' }
          detail = EvaluationDetail.new(nil, nil, { kind: 'OFF' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns an error if off variation is too high" do
          flag = {
            key: 'feature',
            on: false,
            offVariation: 999,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c']
          }
          user = { key: 'x' }
          detail = EvaluationDetail.new(nil, nil,
            { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns an error if off variation is negative" do
          flag = {
            key: 'feature',
            on: false,
            offVariation: -1,
            fallthrough: { variation: 0 },
            variations: ['a', 'b', 'c']
          }
          user = { key: 'x' }
          detail = EvaluationDetail.new(nil, nil,
            { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns off variation if prerequisite is not found" do
          flag = {
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'badfeature', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          }
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1,
            { kind: 'PREREQUISITE_FAILED', prerequisiteKey: 'badfeature' })
          e = subject.new(get_things( 'badfeature' => nil ), get_nothing, logger)
          result = e.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns off variation and event if prerequisite of a prerequisite is not found" do
          flag = {
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'feature1', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1
          }
          flag1 = {
            key: 'feature1',
            on: true,
            prerequisites: [{key: 'feature2', variation: 1}], # feature2 doesn't exist
            fallthrough: { variation: 0 },
            variations: ['d', 'e'],
            version: 2
          }
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1,
            { kind: 'PREREQUISITE_FAILED', prerequisiteKey: 'feature1' })
          events_should_be = [{
            kind: 'feature', key: 'feature1', user: user, value: nil, default: nil, variation: nil, version: 2, prereqOf: 'feature0'
          }]
          get_flag = get_things('feature1' => flag1, 'feature2' => nil)
          e = subject.new(get_flag, get_nothing, logger)
          result = e.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(events_should_be)
        end

        it "returns off variation and event if prerequisite is off" do
          flag = {
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'feature1', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1
          }
          flag1 = {
            key: 'feature1',
            on: false,
            # note that even though it returns the desired variation, it is still off and therefore not a match
            offVariation: 1,
            fallthrough: { variation: 0 },
            variations: ['d', 'e'],
            version: 2
          }
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1,
            { kind: 'PREREQUISITE_FAILED', prerequisiteKey: 'feature1' })
          events_should_be = [{
            kind: 'feature', key: 'feature1', user: user, variation: 1, value: 'e', default: nil, version: 2, prereqOf: 'feature0'
          }]
          get_flag = get_things({ 'feature1' => flag1 })
          e = subject.new(get_flag, get_nothing, logger)
          result = e.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(events_should_be)
        end

        it "returns off variation and event if prerequisite is not met" do
          flag = {
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'feature1', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1
          }
          flag1 = {
            key: 'feature1',
            on: true,
            fallthrough: { variation: 0 },
            variations: ['d', 'e'],
            version: 2
          }
          user = { key: 'x' }
          detail = EvaluationDetail.new('b', 1,
            { kind: 'PREREQUISITE_FAILED', prerequisiteKey: 'feature1' })
          events_should_be = [{
            kind: 'feature', key: 'feature1', user: user, variation: 0, value: 'd', default: nil, version: 2, prereqOf: 'feature0'
          }]
          get_flag = get_things({ 'feature1' => flag1 })
          e = subject.new(get_flag, get_nothing, logger)
          result = e.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(events_should_be)
        end

        it "returns fallthrough variation and event if prerequisite is met and there are no rules" do
          flag = {
            key: 'feature0',
            on: true,
            prerequisites: [{key: 'feature1', variation: 1}],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c'],
            version: 1
          }
          flag1 = {
            key: 'feature1',
            on: true,
            fallthrough: { variation: 1 },
            variations: ['d', 'e'],
            version: 2
          }
          user = { key: 'x' }
          detail = EvaluationDetail.new('a', 0, { kind: 'FALLTHROUGH' })
          events_should_be = [{
            kind: 'feature', key: 'feature1', user: user, variation: 1, value: 'e', default: nil, version: 2, prereqOf: 'feature0'
          }]
          get_flag = get_things({ 'feature1' => flag1 })
          e = subject.new(get_flag, get_nothing, logger)
          result = e.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(events_should_be)
        end

        it "returns an error if fallthrough variation is too high" do
          flag = {
            key: 'feature',
            on: true,
            fallthrough: { variation: 999 },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          }
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil, { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns an error if fallthrough variation is negative" do
          flag = {
            key: 'feature',
            on: true,
            fallthrough: { variation: -1 },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          }
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil, { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns an error if fallthrough has no variation or rollout" do
          flag = {
            key: 'feature',
            on: true,
            fallthrough: { },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          }
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil, { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns an error if fallthrough has a rollout with no variations" do
          flag = {
            key: 'feature',
            on: true,
            fallthrough: { rollout: { variations: [] } },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          }
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil, { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "matches user from targets" do
          flag = {
            key: 'feature',
            on: true,
            targets: [
              { values: [ 'whoever', 'userkey' ], variation: 2 }
            ],
            fallthrough: { variation: 0 },
            offVariation: 1,
            variations: ['a', 'b', 'c']
          }
          user = { key: 'userkey' }
          detail = EvaluationDetail.new('c', 2, { kind: 'TARGET_MATCH' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "matches user from rules" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 1 }
          flag = boolean_flag_with_rules([rule])
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(true, 1,
            { kind: 'RULE_MATCH', ruleIndex: 0, ruleId: 'ruleid' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns an error if rule variation is too high" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 999 }
          flag = boolean_flag_with_rules([rule])
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil,
            { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns an error if rule variation is negative" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: -1 }
          flag = boolean_flag_with_rules([rule])
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil,
            { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns an error if rule has neither variation nor rollout" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }] }
          flag = boolean_flag_with_rules([rule])
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil,
            { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "returns an error if rule has a rollout with no variations" do
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
            rollout: { variations: [] } }
          flag = boolean_flag_with_rules([rule])
          user = { key: 'userkey' }
          detail = EvaluationDetail.new(nil, nil,
            { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail).to eq(detail)
          expect(result.events).to eq(nil)
        end

        it "coerces user key to a string for evaluation" do
          clause = { attribute: 'key', op: 'in', values: ['999'] }
          flag = boolean_flag_with_clauses([clause])
          user = { key: 999 }
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail.value).to eq(true)
        end

        it "coerces secondary key to a string for evaluation" do
          # We can't really verify that the rollout calculation works correctly, but we can at least
          # make sure it doesn't error out if there's a non-string secondary value (ch35189)
          rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
            rollout: { salt: '', variations: [ { weight: 100000, variation: 1 } ] } }
          flag = boolean_flag_with_rules([rule])
          user = { key: "userkey", secondary: 999 }
          result = basic_evaluator.evaluate(flag, user, factory)
          expect(result.detail.reason).to eq({ kind: 'RULE_MATCH', ruleIndex: 0, ruleId: 'ruleid'})
        end
      end

      describe "clause" do
        it "can match built-in attribute" do
          user = { key: 'x', name: 'Bob' }
          clause = { attribute: 'name', op: 'in', values: ['Bob'] }
          flag = boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, user, factory).detail.value).to be true
        end

        it "can match custom attribute" do
          user = { key: 'x', name: 'Bob', custom: { legs: 4 } }
          clause = { attribute: 'legs', op: 'in', values: [4] }
          flag = boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, user, factory).detail.value).to be true
        end

        it "returns false for missing attribute" do
          user = { key: 'x', name: 'Bob' }
          clause = { attribute: 'legs', op: 'in', values: [4] }
          flag = boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, user, factory).detail.value).to be false
        end

        it "returns false for unknown operator" do
          user = { key: 'x', name: 'Bob' }
          clause = { attribute: 'name', op: 'unknown', values: [4] }
          flag = boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, user, factory).detail.value).to be false
        end

        it "does not stop evaluating rules after clause with unknown operator" do
          user = { key: 'x', name: 'Bob' }
          clause0 = { attribute: 'name', op: 'unknown', values: [4] }
          rule0 = { clauses: [ clause0 ], variation: 1 }
          clause1 = { attribute: 'name', op: 'in', values: ['Bob'] }
          rule1 = { clauses: [ clause1 ], variation: 1 }
          flag = boolean_flag_with_rules([rule0, rule1])
          expect(basic_evaluator.evaluate(flag, user, factory).detail.value).to be true
        end

        it "can be negated" do
          user = { key: 'x', name: 'Bob' }
          clause = { attribute: 'name', op: 'in', values: ['Bob'], negate: true }
          flag = boolean_flag_with_clauses([clause])
          expect(basic_evaluator.evaluate(flag, user, factory).detail.value).to be false
        end

        it "retrieves segment from segment store for segmentMatch operator" do
          segment = {
            key: 'segkey',
            included: [ 'userkey' ],
            version: 1,
            deleted: false
          }
          get_segment = get_things({ 'segkey' => segment })
          e = subject.new(get_nothing, get_segment, logger)
          user = { key: 'userkey' }
          clause = { attribute: '', op: 'segmentMatch', values: ['segkey'] }
          flag = boolean_flag_with_clauses([clause])
          expect(e.evaluate(flag, user, factory).detail.value).to be true
        end

        it "falls through with no errors if referenced segment is not found" do
          e = subject.new(get_nothing, get_things({ 'segkey' => nil }), logger)
          user = { key: 'userkey' }
          clause = { attribute: '', op: 'segmentMatch', values: ['segkey'] }
          flag = boolean_flag_with_clauses([clause])
          expect(e.evaluate(flag, user, factory).detail.value).to be false
        end

        it "can be negated" do
          user = { key: 'x', name: 'Bob' }
          clause = { attribute: 'name', op: 'in', values: ['Bob'] }
          flag = boolean_flag_with_clauses([clause])
          expect {
            clause[:negate] = true
          }.to change {basic_evaluator.evaluate(flag, user, factory).detail.value}.from(true).to(false)
        end
      end

      def make_segment(key)
        {
          key: key,
          included: [],
          excluded: [],
          salt: 'abcdef',
          version: 1
        }
      end

      def make_segment_match_clause(segment)
        {
          op: :segmentMatch,
          values: [ segment[:key] ],
          negate: false
        }
      end

      def make_user_matching_clause(user, attr)
        {
          attribute: attr.to_s,
          op: :in,
          values: [ user[attr.to_sym] ],
          negate: false
        }
      end

      describe 'segment matching' do
        def test_segment_match(segment)
          clause = make_segment_match_clause(segment)
          flag = boolean_flag_with_clauses([clause])
          e = subject.new(get_nothing, get_things({ segment[:key] => segment }), logger)
          e.evaluate(flag, user, factory).detail.value
        end

        it 'explicitly includes user' do
          segment = make_segment('segkey')
          segment[:included] = [ user[:key] ]
          expect(test_segment_match(segment)).to be true
        end

        it 'explicitly excludes user' do
          segment = make_segment('segkey')
          segment[:excluded] = [ user[:key] ]
          expect(test_segment_match(segment)).to be false
        end

        it 'both includes and excludes user; include takes priority' do
          segment = make_segment('segkey')
          segment[:included] = [ user[:key] ]
          segment[:excluded] = [ user[:key] ]
          expect(test_segment_match(segment)).to be true
        end

        it 'matches user by rule when weight is absent' do
          segClause = make_user_matching_clause(user, :email)
          segRule = {
            clauses: [ segClause ]
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(segment)).to be true
        end

        it 'matches user by rule when weight is nil' do
          segClause = make_user_matching_clause(user, :email)
          segRule = {
            clauses: [ segClause ],
            weight: nil
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(segment)).to be true
        end

        it 'matches user with full rollout' do
          segClause = make_user_matching_clause(user, :email)
          segRule = {
            clauses: [ segClause ],
            weight: 100000
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(segment)).to be true
        end

        it "doesn't match user with zero rollout" do
          segClause = make_user_matching_clause(user, :email)
          segRule = {
            clauses: [ segClause ],
            weight: 0
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(segment)).to be false
        end

        it "matches user with multiple clauses" do
          segClause1 = make_user_matching_clause(user, :email)
          segClause2 = make_user_matching_clause(user, :name)
          segRule = {
            clauses: [ segClause1, segClause2 ]
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(segment)).to be true
        end

        it "doesn't match user with multiple clauses if a clause doesn't match" do
          segClause1 = make_user_matching_clause(user, :email)
          segClause2 = make_user_matching_clause(user, :name)
          segClause2[:values] = [ 'wrong' ]
          segRule = {
            clauses: [ segClause1, segClause2 ]
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(segment)).to be false
        end
      end
    end
  end
end
