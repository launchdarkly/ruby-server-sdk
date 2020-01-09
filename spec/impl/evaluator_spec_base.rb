require "spec_helper"

module LaunchDarkly
  module Impl
    module EvaluatorSpecBase
      def factory
        EventFactory.new(false)
      end

      def user
        {
          key: "userkey",
          email: "test@example.com",
          name: "Bob"
        }
      end

      def logger
        ::Logger.new($stdout, level: ::Logger::FATAL)
      end

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

      def make_user_matching_clause(user, attr)
        {
          attribute: attr.to_s,
          op: :in,
          values: [ user[attr.to_sym] ],
          negate: false
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
    end

    RSpec.configure { |c| c.include EvaluatorSpecBase, :evaluator_spec_base => true }
  end
end
