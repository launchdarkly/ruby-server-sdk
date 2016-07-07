require "date"

module LaunchDarkly
  module Operators
    operators = {
      in: 
        lambda do |a, b|
          a == b
        end,
      endsWith: 
        lambda do |a, b|
          (a.is_a? String) && (a.end_with? b)
        end,
      startsWith: 
        lambda do |a, b|
          (a.is_a? String) && (a.start_with? b)
        end,
      matches:
        lambda do |a, b|
          (a.is_a? String) && !(Regexp.new a).match(b).nil?
        end,
      contains:
        lambda do |a, b|
          (a.is_a? String) && (a.include? b)
        end,
      lessThan:
        lambda do |a, b|
          (a.is_a? Numeric) && (a < b)
        end,
      lessThanOrEqual:
        lambda do |a, b|
          (a.is_a? Numeric) && (a <= b)
        end,
      greaterThan:
        lambda do |a, b|
          (a.is_a? Numeric) && (a > b)
        end,
      greaterThanOrEqual:
        lambda do |a, b|
          (a.is_a? Numeric) && (a >= b)
        end,
      greaterThanOrEqual:
        lambda do |a, b|
          (a.is_a? Numeric) && (a >= b)
        end,
      before:
        lambda do |a, b|
          ((a.is_a? Numeric) && (a < b)) || ((a.is_a? String) && (DateTime.rfc3339(a).to_time.utc < DateTime.rfc3339(b).to_time.utc))
        end,
      after:
        lambda do |a, b|
          ((a.is_a? Numeric) && (a > b)) || ((a.is_a? String) && (DateTime.rfc3339(a).to_time.utc > DateTime.rfc3339(b).to_time.utc))
        end
    }
  end
end