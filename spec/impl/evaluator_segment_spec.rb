require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    evaluator_tests_with_and_without_preprocessing "Evaluator (segments)" do |desc, factory|
      describe "#{desc} - evaluate", :evaluator_spec_base => true do
        def test_segment_match(factory, segment, context)
          clause = make_segment_match_clause(segment, context.individual_context(0).kind)
          flag = factory.boolean_flag_with_clauses([clause])
          e = EvaluatorBuilder.new(logger).with_segment(segment).build
          e.evaluate(flag, context).detail.value
        end

        it "retrieves segment from segment store for segmentMatch operator" do
          segment = {
            key: 'segkey',
            included: [ 'userkey' ],
            version: 1,
            deleted: false,
          }
          e = EvaluatorBuilder.new(logger).with_segment(segment).build
          flag = factory.boolean_flag_with_clauses([make_segment_match_clause(segment)])
          expect(e.evaluate(flag, user).detail.value).to be true
        end

        it "falls through with no errors if referenced segment is not found" do
          e = EvaluatorBuilder.new(logger).with_unknown_segment('segkey').build
          clause = { attribute: '', op: 'segmentMatch', values: ['segkey'] }
          flag = factory.boolean_flag_with_clauses([clause])
          expect(e.evaluate(flag, user).detail.value).to be false
        end

        it 'explicitly includes user' do
          segment = make_segment('segkey')
          segment[:included] = [ user.key ]
          expect(test_segment_match(factory, segment, user)).to be true
        end

        it 'explicitly includes a specific context kind' do
          org_context = LDContext::create({ key: "orgkey", kind: "org" })
          device_context = LDContext::create({ key: "devicekey", kind: "device" })
          multi_context = LDContext::create_multi([org_context, device_context])

          segment = make_segment('segkey')
          segment[:includedContexts] = [{ contextKind: "org", values: ["orgkey"] }]

          expect(test_segment_match(factory, segment, org_context)).to be true
          expect(test_segment_match(factory, segment, device_context)).to be false
          expect(test_segment_match(factory, segment, multi_context)).to be true
        end

        it 'explicitly excludes user' do
          segment = make_segment('segkey')
          segment[:excluded] = [ user.key ]
          expect(test_segment_match(factory, segment, user)).to be false
        end

        it 'explicitly excludes a specific context kind' do
          org_context = LDContext::create({ key: "orgkey", kind: "org" })
          device_context = LDContext::create({ key: "devicekey", kind: "device" })
          multi_context = LDContext::create_multi([org_context, device_context])

          segment = make_segment('segkey')
          segment[:excludedContexts] = [{ contextKind: "org", values: ["orgkey"] }]

          org_clause = make_user_matching_clause(org_context, :key)
          device_clause = make_user_matching_clause(device_context, :key)
          segment[:rules] = [ { clauses: [ org_clause ] }, { clauses: [ device_clause ] } ]

          expect(test_segment_match(factory, segment, org_context)).to be false
          expect(test_segment_match(factory, segment, device_context)).to be true
          expect(test_segment_match(factory, segment, multi_context)).to be false
        end

        it 'both includes and excludes user; include takes priority' do
          segment = make_segment('segkey')
          segment[:included] = [ user.key ]
          segment[:excluded] = [ user.key ]
          expect(test_segment_match(factory, segment, user)).to be true
        end

        it 'matches user by rule when weight is absent' do
          segClause = make_user_matching_clause(user, :email)
          segRule = {
            clauses: [ segClause ],
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(factory, segment, user)).to be true
        end

        it 'matches user by rule when weight is nil' do
          segClause = make_user_matching_clause(user, :email)
          segRule = {
            clauses: [ segClause ],
            weight: nil,
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(factory, segment, user)).to be true
        end

        it 'matches user with full rollout' do
          segClause = make_user_matching_clause(user, :email)
          segRule = {
            clauses: [ segClause ],
            weight: 100000,
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(factory, segment, user)).to be true
        end

        it "doesn't match user with zero rollout" do
          segClause = make_user_matching_clause(user, :email)
          segRule = {
            clauses: [ segClause ],
            weight: 0,
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(factory, segment, user)).to be false
        end

        it "matches user with multiple clauses" do
          segClause1 = make_user_matching_clause(user, :email)
          segClause2 = make_user_matching_clause(user, :name)
          segRule = {
            clauses: [ segClause1, segClause2 ],
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(factory, segment, user)).to be true
        end

        it "doesn't match user with multiple clauses if a clause doesn't match" do
          segClause1 = make_user_matching_clause(user, :email)
          segClause2 = make_user_matching_clause(user, :name)
          segClause2[:values] = [ 'wrong' ]
          segRule = {
            clauses: [ segClause1, segClause2 ],
          }
          segment = make_segment('segkey')
          segment[:rules] = [ segRule ]
          expect(test_segment_match(factory, segment, user)).to be false
        end
      end
    end
  end
end
