require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    describe "Evaluator (segments)", :evaluator_spec_base => true do
      subject { Evaluator }

      def test_segment_match(segment)
        clause = make_segment_match_clause(segment)
        flag = boolean_flag_with_clauses([clause])
        e = EvaluatorBuilder.new(logger).with_segment(segment).build
        e.evaluate(flag, user).detail.value
      end

      it "retrieves segment from segment store for segmentMatch operator" do
        segment = {
          key: 'segkey',
          included: [ 'userkey' ],
          version: 1,
          deleted: false,
        }
        e = EvaluatorBuilder.new(logger).with_segment(segment).build
        flag = boolean_flag_with_clauses([make_segment_match_clause(segment)])
        expect(e.evaluate(flag, user).detail.value).to be true
      end

      it "falls through with no errors if referenced segment is not found" do
        e = EvaluatorBuilder.new(logger).with_unknown_segment('segkey').build
        clause = { attribute: '', op: 'segmentMatch', values: ['segkey'] }
        flag = boolean_flag_with_clauses([clause])
        expect(e.evaluate(flag, user).detail.value).to be false
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
          clauses: [ segClause ],
        }
        segment = make_segment('segkey')
        segment[:rules] = [ segRule ]
        expect(test_segment_match(segment)).to be true
      end

      it 'matches user by rule when weight is nil' do
        segClause = make_user_matching_clause(user, :email)
        segRule = {
          clauses: [ segClause ],
          weight: nil,
        }
        segment = make_segment('segkey')
        segment[:rules] = [ segRule ]
        expect(test_segment_match(segment)).to be true
      end

      it 'matches user with full rollout' do
        segClause = make_user_matching_clause(user, :email)
        segRule = {
          clauses: [ segClause ],
          weight: 100000,
        }
        segment = make_segment('segkey')
        segment[:rules] = [ segRule ]
        expect(test_segment_match(segment)).to be true
      end

      it "doesn't match user with zero rollout" do
        segClause = make_user_matching_clause(user, :email)
        segRule = {
          clauses: [ segClause ],
          weight: 0,
        }
        segment = make_segment('segkey')
        segment[:rules] = [ segRule ]
        expect(test_segment_match(segment)).to be false
      end

      it "matches user with multiple clauses" do
        segClause1 = make_user_matching_clause(user, :email)
        segClause2 = make_user_matching_clause(user, :name)
        segRule = {
          clauses: [ segClause1, segClause2 ],
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
          clauses: [ segClause1, segClause2 ],
        }
        segment = make_segment('segkey')
        segment[:rules] = [ segRule ]
        expect(test_segment_match(segment)).to be false
      end
    end
  end
end
