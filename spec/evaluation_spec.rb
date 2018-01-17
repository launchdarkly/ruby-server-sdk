require "spec_helper"


describe LaunchDarkly::Evaluation do
  subject { LaunchDarkly::Evaluation }
  let(:features) { LaunchDarkly::InMemoryFeatureStore.new }
  let(:segments) { LaunchDarkly::InMemorySegmentStore.new }
  let(:user) {
    {
      key: "userkey",
      email: "test@example.com",
      name: "Bob"
    }
  }

  def make_flag(key)
    {
      key: key,
      rules: [],
      variations: [ false, true ],
      on: true,
      fallthrough: { variation: 0 },
      version: 1
    }
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

  include LaunchDarkly::Evaluation

  describe 'segment matching' do
    it 'explicitly includes user' do
      segment = make_segment('segkey')
      segment[:included] = [ user[:key] ]
      segments.upsert('segkey', segment)
      clause = make_segment_match_clause(segment)

      result = clause_match_user(clause, user, segments)
      expect(result).to be true
    end

    it 'explicitly excludes user' do
      segment = make_segment('segkey')
      segment[:excluded] = [ user[:key] ]
      segments.upsert('segkey', segment)
      clause = make_segment_match_clause(segment)

      result = clause_match_user(clause, user, segments)
      expect(result).to be false
    end

    it 'both includes and excludes user; include takes priority' do
      segment = make_segment('segkey')
      segment[:included] = [ user[:key] ]
      segment[:excluded] = [ user[:key] ]
      segments.upsert('segkey', segment)
      clause = make_segment_match_clause(segment)

      result = clause_match_user(clause, user, segments)
      expect(result).to be true
    end

    it 'matches user with full rollout' do
      segClause = make_user_matching_clause(user, :email)
      segRule = {
        clauses: [ segClause ],
        weight: 100000
      }
      segment = make_segment('segkey')
      segment[:rules] = [ segRule ]
      segments.upsert('segkey', segment)
      clause = make_segment_match_clause(segment)

      result = clause_match_user(clause, user, segments)
      expect(result).to be true
    end

    it 'doesn''t match user with zero rollout' do
      segClause = make_user_matching_clause(user, :email)
      segRule = {
        clauses: [ segClause ],
        weight: 0
      }
      segment = make_segment('segkey')
      segment[:rules] = [ segRule ]
      segments.upsert('segkey', segment)
      clause = make_segment_match_clause(segment)

      result = clause_match_user(clause, user, segments)
      expect(result).to be false
    end

    it 'matches user with multiple clauses' do
      segClause1 = make_user_matching_clause(user, :email)
      segClause2 = make_user_matching_clause(user, :name)
      segRule = {
        clauses: [ segClause1, segClause2 ]
      }
      segment = make_segment('segkey')
      segment[:rules] = [ segRule ]
      segments.upsert('segkey', segment)
      clause = make_segment_match_clause(segment)

      result = clause_match_user(clause, user, segments)
      expect(result).to be true
    end

    it 'doesn''t match user with multiple clauses' do
      segClause1 = make_user_matching_clause(user, :email)
      segClause2 = make_user_matching_clause(user, :name)
      segClause2[:values] = [ 'wrong' ]
      segRule = {
        clauses: [ segClause1, segClause2 ]
      }
      segment = make_segment('segkey')
      segment[:rules] = [ segRule ]
      segments.upsert('segkey', segment)
      clause = make_segment_match_clause(segment)

      result = clause_match_user(clause, user, segments)
      expect(result).to be false
    end
  end
end
