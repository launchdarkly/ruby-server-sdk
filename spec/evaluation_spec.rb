require "spec_helper"

describe LaunchDarkly::Evaluation do
  subject { LaunchDarkly::Evaluation }

  include LaunchDarkly::Evaluation

  let(:features) { LaunchDarkly::InMemoryFeatureStore.new }

  let(:user) {
    {
      key: "userkey",
      email: "test@example.com",
      name: "Bob"
    }
  }

  let(:logger) { LaunchDarkly::Config.default_logger }

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
      detail = LaunchDarkly::EvaluationDetail.new('b', 1, { kind: 'OFF' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
    end

    it "returns nil if flag is off and off variation is unspecified" do
      flag = {
        key: 'feature',
        on: false,
        fallthrough: { variation: 0 },
        variations: ['a', 'b', 'c']
      }
      user = { key: 'x' }
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil, { kind: 'OFF' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
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
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil,
        { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
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
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil,
        { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
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
      detail = LaunchDarkly::EvaluationDetail.new('b', 1,
        { kind: 'PREREQUISITE_FAILED', prerequisiteKey: 'badfeature' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
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
      features.upsert(LaunchDarkly::FEATURES, flag1)
      user = { key: 'x' }
      detail = LaunchDarkly::EvaluationDetail.new('b', 1,
        { kind: 'PREREQUISITE_FAILED', prerequisiteKey: 'feature1' })
      events_should_be = [{
        kind: 'feature', key: 'feature1', user: user, variation: nil, value: nil, version: 2, prereqOf: 'feature0',
        trackEvents: nil, debugEventsUntilDate: nil
      }]
      result = evaluate(flag, user, features, logger)
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
      features.upsert(LaunchDarkly::FEATURES, flag1)
      user = { key: 'x' }
      detail = LaunchDarkly::EvaluationDetail.new('b', 1,
        { kind: 'PREREQUISITE_FAILED', prerequisiteKey: 'feature1' })
      events_should_be = [{
        kind: 'feature', key: 'feature1', user: user, variation: 1, value: 'e', version: 2, prereqOf: 'feature0',
        trackEvents: nil, debugEventsUntilDate: nil
      }]
      result = evaluate(flag, user, features, logger)
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
      features.upsert(LaunchDarkly::FEATURES, flag1)
      user = { key: 'x' }
      detail = LaunchDarkly::EvaluationDetail.new('b', 1,
        { kind: 'PREREQUISITE_FAILED', prerequisiteKey: 'feature1' })
      events_should_be = [{
        kind: 'feature', key: 'feature1', user: user, variation: 0, value: 'd', version: 2, prereqOf: 'feature0',
        trackEvents: nil, debugEventsUntilDate: nil
      }]
      result = evaluate(flag, user, features, logger)
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
      features.upsert(LaunchDarkly::FEATURES, flag1)
      user = { key: 'x' }
      detail = LaunchDarkly::EvaluationDetail.new('a', 0, { kind: 'FALLTHROUGH' })
      events_should_be = [{
        kind: 'feature', key: 'feature1', user: user, variation: 1, value: 'e', version: 2, prereqOf: 'feature0',
        trackEvents: nil, debugEventsUntilDate: nil
      }]
      result = evaluate(flag, user, features, logger)
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
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil, { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
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
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil, { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
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
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil, { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
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
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil, { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
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
      detail = LaunchDarkly::EvaluationDetail.new('c', 2, { kind: 'TARGET_MATCH' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
    end

    it "matches user from rules" do
      rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 1 }
      flag = boolean_flag_with_rules([rule])
      user = { key: 'userkey' }
      detail = LaunchDarkly::EvaluationDetail.new(true, 1,
        { kind: 'RULE_MATCH', ruleIndex: 0, ruleId: 'ruleid' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
    end

    it "returns an error if rule variation is too high" do
      rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: 999 }
      flag = boolean_flag_with_rules([rule])
      user = { key: 'userkey' }
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil,
        { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
    end

    it "returns an error if rule variation is negative" do
      rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }], variation: -1 }
      flag = boolean_flag_with_rules([rule])
      user = { key: 'userkey' }
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil,
        { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
    end

    it "returns an error if rule has neither variation nor rollout" do
      rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }] }
      flag = boolean_flag_with_rules([rule])
      user = { key: 'userkey' }
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil,
        { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
    end

    it "returns an error if rule has a rollout with no variations" do
      rule = { id: 'ruleid', clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
        rollout: { variations: [] } }
      flag = boolean_flag_with_rules([rule])
      user = { key: 'userkey' }
      detail = LaunchDarkly::EvaluationDetail.new(nil, nil,
        { kind: 'ERROR', errorKind: 'MALFORMED_FLAG' })
      result = evaluate(flag, user, features, logger)
      expect(result.detail).to eq(detail)
      expect(result.events).to eq([])
    end
  end

  describe "clause" do
    it "can match built-in attribute" do
      user = { key: 'x', name: 'Bob' }
      clause = { attribute: 'name', op: 'in', values: ['Bob'] }
      flag = boolean_flag_with_clauses([clause])
      expect(evaluate(flag, user, features, logger).detail.value).to be true
    end

    it "can match custom attribute" do
      user = { key: 'x', name: 'Bob', custom: { legs: 4 } }
      clause = { attribute: 'legs', op: 'in', values: [4] }
      flag = boolean_flag_with_clauses([clause])
      expect(evaluate(flag, user, features, logger).detail.value).to be true
    end

    it "returns false for missing attribute" do
      user = { key: 'x', name: 'Bob' }
      clause = { attribute: 'legs', op: 'in', values: [4] }
      flag = boolean_flag_with_clauses([clause])
      expect(evaluate(flag, user, features, logger).detail.value).to be false
    end

    it "returns false for unknown operator" do
      user = { key: 'x', name: 'Bob' }
      clause = { attribute: 'name', op: 'unknown', values: [4] }
      flag = boolean_flag_with_clauses([clause])
      expect(evaluate(flag, user, features, logger).detail.value).to be false
    end

    it "does not stop evaluating rules after clause with unknown operator" do
      user = { key: 'x', name: 'Bob' }
      clause0 = { attribute: 'name', op: 'unknown', values: [4] }
      rule0 = { clauses: [ clause0 ], variation: 1 }
      clause1 = { attribute: 'name', op: 'in', values: ['Bob'] }
      rule1 = { clauses: [ clause1 ], variation: 1 }
      flag = boolean_flag_with_rules([rule0, rule1])
      expect(evaluate(flag, user, features, logger).detail.value).to be true
    end

    it "can be negated" do
      user = { key: 'x', name: 'Bob' }
      clause = { attribute: 'name', op: 'in', values: ['Bob'], negate: true }
      flag = boolean_flag_with_clauses([clause])
      expect(evaluate(flag, user, features, logger).detail.value).to be false
    end

    it "retrieves segment from segment store for segmentMatch operator" do
      segment = {
        key: 'segkey',
        included: [ 'userkey' ],
        version: 1,
        deleted: false
      }
      features.upsert(LaunchDarkly::SEGMENTS, segment)

      user = { key: 'userkey' }
      clause = { attribute: '', op: 'segmentMatch', values: ['segkey'] }
      flag = boolean_flag_with_clauses([clause])
      expect(evaluate(flag, user, features, logger).detail.value).to be true
    end

    it "falls through with no errors if referenced segment is not found" do
      user = { key: 'userkey' }
      clause = { attribute: '', op: 'segmentMatch', values: ['segkey'] }
      flag = boolean_flag_with_clauses([clause])
      expect(evaluate(flag, user, features, logger).detail.value).to be false
    end

    it "can be negated" do
      user = { key: 'x', name: 'Bob' }
      clause = { attribute: 'name', op: 'in', values: ['Bob'] }
      flag = boolean_flag_with_clauses([clause])
      expect {
         clause[:negate] = true
      }.to change {evaluate(flag, user, features, logger).detail.value}.from(true).to(false)
    end
  end

  describe "operators" do
    dateStr1 = "2017-12-06T00:00:00.000-07:00"
    dateStr2 = "2017-12-06T00:01:01.000-07:00"
    dateMs1 = 10000000
    dateMs2 = 10000001
    invalidDate = "hey what's this?"

    operatorTests = [
      # numeric comparisons
      [ :in,                 99,      99,      true ],
      [ :in,                 99.0001, 99.0001, true ],
      [ :in,                 99,      99.0001, false ],
      [ :in,                 99.0001, 99,      false ],
      [ :lessThan,           99,      99.0001, true ],
      [ :lessThan,           99.0001, 99,      false ],
      [ :lessThan,           99,      99,      false ],
      [ :lessThanOrEqual,    99,      99.0001, true ],
      [ :lessThanOrEqual,    99.0001, 99,      false ],
      [ :lessThanOrEqual,    99,      99,      true ],
      [ :greaterThan,        99.0001, 99,      true ],
      [ :greaterThan,        99,      99.0001, false ],
      [ :greaterThan,        99,      99,      false ],
      [ :greaterThanOrEqual, 99.0001, 99,      true ],
      [ :greaterThanOrEqual, 99,      99.0001, false ],
      [ :greaterThanOrEqual, 99,      99,      true ],

      # string comparisons
      [ :in,         "x",   "x",   true ],
      [ :in,         "x",   "xyz", false ],
      [ :startsWith, "xyz", "x",   true ],
      [ :startsWith, "x",   "xyz", false ],
      [ :endsWith,   "xyz", "z",   true ],
      [ :endsWith,   "z",   "xyz", false ],
      [ :contains,   "xyz", "y",   true ],
      [ :contains,   "y",   "xyz", false ],

      # mixed strings and numbers
      [ :in,                 "99", 99, false ],
      [ :in,                  99, "99", false ],
      #[ :contains,           "99", 99, false ],    # currently throws exception - would return false in Java SDK
      #[ :startsWith,         "99", 99, false ],  # currently throws exception - would return false in Java SDK
      #[ :endsWith,           "99", 99, false ]     # currently throws exception - would return false in Java SDK
      [ :lessThanOrEqual,    "99", 99, false ],
      #[ :lessThanOrEqual,    99, "99", false ],    # currently throws exception - would return false in Java SDK
      [ :greaterThanOrEqual, "99", 99, false ],
      #[ :greaterThanOrEqual, 99, "99", false ], # currently throws exception - would return false in Java SDK
      
      # regex
      [ :matches, "hello world", "hello.*rld",     true ],
      [ :matches, "hello world", "hello.*orl",     true ],
      [ :matches, "hello world", "l+",             true ],
      [ :matches, "hello world", "(world|planet)", true ],
      [ :matches, "hello world", "aloha",          false ],
      #[ :matches, "hello world", "***not a regex", false ]   # currently throws exception - same as Java SDK

      # dates
      [ :before, dateStr1, dateStr2,    true ],
      [ :before, dateMs1,  dateMs2,     true ],
      [ :before, dateStr2, dateStr1,    false ],
      [ :before, dateMs2,  dateMs1,     false ],
      [ :before, dateStr1, dateStr1,    false ],
      [ :before, dateMs1,  dateMs1,     false ],
      [ :before, dateStr1, invalidDate, false ],
      [ :after,  dateStr1, dateStr2,    false ],
      [ :after,  dateMs1,  dateMs2,     false ],
      [ :after,  dateStr2, dateStr1,    true ],
      [ :after,  dateMs2,  dateMs1,     true ],
      [ :after,  dateStr1, dateStr1,    false ],
      [ :after,  dateMs1,  dateMs1,     false ],
      [ :after,  dateStr1, invalidDate, false ],

      # semver
      [ :semVerEqual,       "2.0.1", "2.0.1", true ],
      [ :semVerEqual,       "2.0",   "2.0.0", true ],
      [ :semVerEqual,       "2-rc1", "2.0.0-rc1", true ],
      [ :semVerEqual,       "2+build2", "2.0.0+build2", true ],
      [ :semVerLessThan,    "2.0.0", "2.0.1", true ],
      [ :semVerLessThan,    "2.0",   "2.0.1", true ],
      [ :semVerLessThan,    "2.0.1", "2.0.0", false ],
      [ :semVerLessThan,    "2.0.1", "2.0",   false ],
      [ :semVerLessThan,    "2.0.0-rc", "2.0.0-rc.beta", true ],
      [ :semVerGreaterThan, "2.0.1", "2.0.0", true ],
      [ :semVerGreaterThan, "2.0.1", "2.0",   true ],
      [ :semVerGreaterThan, "2.0.0", "2.0.1", false ],
      [ :semVerGreaterThan, "2.0",   "2.0.1", false ],
      [ :semVerGreaterThan, "2.0.0-rc.1", "2.0.0-rc.0", true ],
      [ :semVerLessThan,    "2.0.1", "xbad%ver", false ],
      [ :semVerGreaterThan, "2.0.1", "xbad%ver", false ]
    ]

    operatorTests.each do |params|
      op = params[0]
      value1 = params[1]
      value2 = params[2]
      shouldBe = params[3]
      it "should return #{shouldBe} for #{value1} #{op} #{value2}" do
        user = { key: 'x', custom: { foo: value1 } }
        clause = { attribute: 'foo', op: op, values: [value2] }
        flag = boolean_flag_with_clauses([clause])
        expect(evaluate(flag, user, features, logger).detail.value).to be shouldBe
      end
    end
  end

  describe "bucket_user" do
    it "gets expected bucket values for specific keys" do
      user = { key: "userKeyA" }
      bucket = bucket_user(user, "hashKey", "key", "saltyA")
      expect(bucket).to be_within(0.0000001).of(0.42157587);

      user = { key: "userKeyB" }
      bucket = bucket_user(user, "hashKey", "key", "saltyA")
      expect(bucket).to be_within(0.0000001).of(0.6708485);

      user = { key: "userKeyC" }
      bucket = bucket_user(user, "hashKey", "key", "saltyA")
      expect(bucket).to be_within(0.0000001).of(0.10343106);
    end

    it "can bucket by int value (equivalent to string)" do
      user = {
        key: "userkey",
        custom: {
          stringAttr: "33333",
          intAttr: 33333
        }
      }
      stringResult = bucket_user(user, "hashKey", "stringAttr", "saltyA")
      intResult = bucket_user(user, "hashKey", "intAttr", "saltyA")

      expect(intResult).to be_within(0.0000001).of(0.54771423)
      expect(intResult).to eq(stringResult)
    end

    it "cannot bucket by float value" do
      user = {
        key: "userkey",
        custom: {
          floatAttr: 33.5
        }
      }
      result = bucket_user(user, "hashKey", "floatAttr", "saltyA")
      expect(result).to eq(0.0)
    end


    it "cannot bucket by bool value" do
      user = {
        key: "userkey",
        custom: {
          boolAttr: true
        }
      }
      result = bucket_user(user, "hashKey", "boolAttr", "saltyA")
      expect(result).to eq(0.0)
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
      features.upsert(LaunchDarkly::SEGMENTS, segment)
      clause = make_segment_match_clause(segment)
      flag = boolean_flag_with_clauses([clause])
      evaluate(flag, user, features, logger).detail.value
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
