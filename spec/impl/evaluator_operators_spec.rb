require "spec_helper"

module LaunchDarkly
  module Impl
    describe EvaluatorOperators do
      subject { EvaluatorOperators }

      describe "operators" do
        date_str_1 = "2017-12-06T00:00:00.000-07:00"
        date_str_2 = "2017-12-06T00:01:01.000-07:00"
        date_ms_1 = 10000000
        date_ms_2 = 10000001
        invalid_date = "hey what's this?"

        operator_tests = [
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
          [ :in,                  "99", 99, false ],
          [ :in,                  99, "99", false ],
          [ :contains,            "99", 99, false ],
          [ :startsWith,          "99", 99, false ],
          [ :endsWith,            "99", 99, false ],
          [ :lessThanOrEqual,     "99", 99, false ],
          [ :lessThanOrEqual,     99, "99", false ],
          [ :greaterThanOrEqual,  "99", 99, false ],
          [ :greaterThanOrEqual,  99, "99", false ],

          # regex
          [ :matches, "hello world", "hello.*rld",     true ],
          [ :matches, "hello world", "hello.*orl",     true ],
          [ :matches, "hello world", "l+",             true ],
          [ :matches, "hello world", "(world|planet)", true ],
          [ :matches, "hello world", "aloha",          false ],
          [ :matches, "hello world", "***not a regex", false ],

          # dates
          [:before, date_str_1, date_str_2, true ],
          [:before, date_ms_1, date_ms_2, true ],
          [:before, date_str_2, date_str_1, false ],
          [:before, date_ms_2, date_ms_1, false ],
          [:before, date_str_1, date_str_1, false ],
          [:before, date_ms_1, date_ms_1, false ],
          [:before, date_str_1, invalid_date, false ],
          [:after, date_str_1, date_str_2, false ],
          [:after, date_ms_1, date_ms_2, false ],
          [:after, date_str_2, date_str_1, true ],
          [:after, date_ms_2, date_ms_1, true ],
          [:after, date_str_1, date_str_1, false ],
          [:after, date_ms_1, date_ms_1, false ],
          [:after, date_str_1, invalid_date, false ],

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
          [ :semVerGreaterThan, "2.0.1", "xbad%ver", false ],
        ]

        operator_tests.each do |params|
          op = params[0]
          value1 = params[1]
          value2 = params[2]
          should_be = params[3]
          it "should return #{should_be} for #{value1} #{op} #{value2}" do
            expect(subject::apply(op, value1, value2)).to be should_be
          end
        end
      end
    end
  end
end
