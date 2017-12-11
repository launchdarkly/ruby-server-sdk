require "spec_helper"

describe LaunchDarkly::Evaluation do
  subject { LaunchDarkly::Evaluation }

  include LaunchDarkly::Evaluation

  describe "clause_match_user" do
    it "can match built-in attribute" do
      user = { key: 'x', name: 'Bob' }
      clause = { attribute: 'name', op: 'in', values: ['Bob'] }
      expect(clause_match_user(clause, user)).to be true
    end

    it "can match custom attribute" do
      user = { key: 'x', name: 'Bob', custom: { legs: 4 } }
      clause = { attribute: 'legs', op: 'in', values: [4] }
      expect(clause_match_user(clause, user)).to be true
    end

    it "returns false for missing attribute" do
      user = { key: 'x', name: 'Bob' }
      clause = { attribute: 'legs', op: 'in', values: [4] }
      expect(clause_match_user(clause, user)).to be false
    end
  end

  describe "operators" do
    n99 = 99
    n99_0001 = 99.0001
    sX = "x"
    sY = "y"
    sZ = "z"
    sXyz = "xyz"
    s99 = "99"
    sHelloWorld = "hello world"
    dateStr1 = "2017-12-06T00:00:00.000-07:00"
    dateStr2 = "2017-12-06T00:01:01.000-07:00"
    dateMs1 = 10000000
    dateMs2 = 10000001
    invalidDate = "hey what's this?"
    v2_0 = "2.0"
    v2_0_0 = "2.0.0"
    v2_0_1 = "2.0.1"
    vInvalid = "xbad%ver"

    operatorTests = [
      # numeric comparisons
      [ :in, n99, n99, true ],
      [ :in, n99_0001, n99_0001, true ],
      [ :in, n99, n99_0001, false ],
      [ :in, n99_0001, n99, false ],
      [ :lessThan, n99, n99_0001, true ],
      [ :lessThan, n99_0001, n99, false ],
      [ :lessThan, n99, n99, false ],
      [ :lessThanOrEqual, n99, n99_0001, true ],
      [ :lessThanOrEqual, n99_0001, n99, false ],
      [ :lessThanOrEqual, n99, n99, true ],
      [ :greaterThan, n99_0001, n99, true ],
      [ :greaterThan, n99, n99_0001, false ],
      [ :greaterThan, n99, n99, false ],
      [ :greaterThanOrEqual, n99_0001, n99, true ],
      [ :greaterThanOrEqual, n99, n99_0001, false ],
      [ :greaterThanOrEqual, n99, n99, true ],

      # string comparisons
      [ :in, sX, sX, true ],
      [ :in, sX, sXyz, false ],
      [ :startsWith, sXyz, sX, true ],
      [ :startsWith, sX, sXyz, false ],
      [ :endsWith, sXyz, sZ, true ],
      [ :endsWith, sZ, sXyz, false ],
      [ :contains, sXyz, sY, true ],
      [ :contains, sY, sXyz, false ],

      # mixed strings and numbers
      [ :in, s99, n99, false ],
      [ :in, n99, s99, false ],
      #[ :contains, s99, n99, false ],    # currently throws exception - would return false in Java SDK
      #[ :startsWith, s99, n99, false ],  # currently throws exception - would return false in Java SDK
      #[ :endsWith, s99, n99, false ]     # currently throws exception - would return false in Java SDK
      [ :lessThanOrEqual, s99, n99, false ],
      #[ :lessThanOrEqual, n99, s99, false ],    # currently throws exception - would return false in Java SDK
      [ :greaterThanOrEqual, s99, n99, false ],
      #[ :greaterThanOrEqual, n99, s99, false ], # currently throws exception - would return false in Java SDK
      
      # regex
      [ :matches, sHelloWorld, "hello.*rld", true ],
      [ :matches, sHelloWorld, "hello.*orl", true ],
      [ :matches, sHelloWorld, "l+", true ],
      [ :matches, sHelloWorld, "(world|planet)", true ],
      [ :matches, sHelloWorld, "aloha", false ],
      #[ :matches, sHelloWorld, new JsonPrimitive("***not a regex"), false ]   # currently throws exception - same as Java SDK

      # dates
      [ :before, dateStr1, dateStr2, true ],
      [ :before, dateMs1, dateMs2, true ],
      [ :before, dateStr2, dateStr1, false ],
      [ :before, dateMs2, dateMs1, false ],
      [ :before, dateStr1, dateStr1, false ],
      [ :before, dateMs1, dateMs1, false ],
      [ :before, dateStr1, invalidDate, false ],
      [ :after, dateStr1, dateStr2, false ],
      [ :after, dateMs1, dateMs2, false ],
      [ :after, dateStr2, dateStr1, true ],
      [ :after, dateMs2, dateMs1, true ],
      [ :after, dateStr1, dateStr1, false ],
      [ :after, dateMs1, dateMs1, false ],
      [ :after, dateStr1, invalidDate, false ],

      # semver
      [ :semVerEqual, v2_0_1, v2_0_1, true ],
      [ :semVerEqual, v2_0, v2_0_0, true ],
          # Note on the above: the sem_version library returns exactly the same object for "2.0" and "2.0.0",
          # which happens to be the behavior we want.
      [ :semVerLessThan, v2_0_0, v2_0_1, true ],
      [ :semVerLessThan, v2_0, v2_0_1, true ],
      [ :semVerLessThan, v2_0_1, v2_0_0, false ],
      [ :semVerLessThan, v2_0_1, v2_0, false ],
      [ :semVerGreaterThan, v2_0_1, v2_0_0, true ],
      [ :semVerGreaterThan, v2_0_1, v2_0, true ],
      [ :semVerGreaterThan, v2_0_0, v2_0_1, false ],
      [ :semVerGreaterThan, v2_0, v2_0_1, false ],
      [ :semVerLessThan, v2_0_1, vInvalid, false ],
      [ :semVerGreaterThan, v2_0_1, vInvalid, false ]
    ]

    operatorTests.each do |params|
      op = params[0]
      value1 = params[1]
      value2 = params[2]
      shouldBe = params[3]
      it "should return #{shouldBe} for #{value1} #{op} #{value2}" do
        user = { key: 'x', custom: { foo: value1 } }
        clause = { attribute: 'foo', op: op, values: [value2] }
        expect(clause_match_user(clause, user)).to be shouldBe
      end
    end
  end
end
