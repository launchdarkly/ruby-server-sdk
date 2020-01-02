require "spec_helper"

describe LaunchDarkly::Impl::EvaluatorOperators do
  subject { LaunchDarkly::Impl::EvaluatorOperators }

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
        expect(subject::apply(op, value1, value2)).to be shouldBe
      end
    end
  end

  describe "user_value" do
    [:key, :ip, :country, :email, :firstName, :lastName, :avatar, :name, :anonymous, :some_custom_attr].each do |attr|
      it "returns nil if property #{attr} is not defined" do
        expect(subject::user_value({}, attr)).to be nil
      end
    end

    [:key, :ip, :country, :email, :firstName, :lastName, :avatar, :name].each do |attr|
      it "gets string value of string property #{attr}" do
        expect(subject::user_value({ attr => 'x' }, attr)).to eq 'x'
      end

      it "coerces non-string value of property #{attr} to string" do
        expect(subject::user_value({ attr => 3 }, attr)).to eq '3'
      end
    end

    it "gets boolean value of property anonymous" do
      expect(subject::user_value({ anonymous: true }, :anonymous)).to be true
      expect(subject::user_value({ anonymous: false }, :anonymous)).to be false
    end

    it "does not coerces non-boolean value of property anonymous" do
      expect(subject::user_value({ anonymous: 3 }, :anonymous)).to eq 3
    end

    it "gets string value of custom property" do
      expect(subject::user_value({ custom: { some_custom_attr: 'x' } }, :some_custom_attr)).to eq 'x'
    end

    it "gets non-string value of custom property" do
      expect(subject::user_value({ custom: { some_custom_attr: 3 } }, :some_custom_attr)).to eq 3
    end
  end
end
