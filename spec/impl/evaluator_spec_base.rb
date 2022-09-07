require "ldclient-rb/impl/big_segments"

require "model_builders"
require "spec_helper"

def evaluator_tests_with_and_without_preprocessing(desc_base)
  # In the evaluator tests, we are really testing two sets of evaluation logic: one where preprocessed
  # results are not available, and one where they are. In normal usage, flags always get preprocessed and
  # we expect evaluations to almost always be able to reuse a preprocessed result-- but we still want to
  # verify that the evaluator works even if preprocessing hasn't happened, since a flag is just a Hash and
  # so we can't do any type-level enforcement to constrain its state. The DataItemFactory abstraction
  # controls whether flags/segments created in these tests do or do not have preprocessing applied.
  [true, false].each do |with_preprocessing|
    pre_desc = with_preprocessing ? "with preprocessing" : "without preprocessing"
    desc = "#{desc_base} - #{pre_desc}"
    yield desc, DataItemFactory.new(with_preprocessing)
  end
end

module LaunchDarkly
  module Impl
    class EvaluatorBuilder
      def initialize(logger)
        @flags = {}
        @segments = {}
        @big_segment_memberships = {}
        @big_segments_status = BigSegmentsStatus::HEALTHY
        @big_segments_queries = []
        @logger = logger
      end

      def with_flag(flag)
        @flags[flag[:key]] = flag
        self
      end

      def with_unknown_flag(key)
        @flags[key] = nil
        self
      end

      def with_segment(segment)
        @segments[segment[:key]] = segment
        self
      end

      def with_unknown_segment(key)
        @segments[key] = nil
        self
      end

      def with_big_segment_for_user(user, segment, included)
        user_key = user[:key]
        @big_segment_memberships[user_key] = {} if !@big_segment_memberships.has_key?(user_key)
        @big_segment_memberships[user_key][Evaluator.make_big_segment_ref(segment)] = included
        self
      end

      def with_big_segments_status(status)
        @big_segments_status = status
        self
      end

      def record_big_segments_queries(destination)
        @big_segments_queries = destination
        self
      end

      def build
        Evaluator.new(method(:get_flag), method(:get_segment),
          @big_segment_memberships.empty? ? nil : method(:get_big_segments),
          @logger)
      end

      private def get_flag(key)
        raise "should not have requested flag #{key}" if !@flags.has_key?(key)
        @flags[key]
      end

      private def get_segment(key)
        raise "should not have requested segment #{key}" if !@segments.has_key?(key)
        @segments[key]
      end

      private def get_big_segments(user_key)
        raise "should not have requested big segments for #{user_key}" if !@big_segment_memberships.has_key?(user_key)
        @big_segments_queries << user_key
        BigSegmentMembershipResult.new(@big_segment_memberships[user_key], @big_segments_status)
      end
    end

    module EvaluatorSpecBase
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

      def basic_evaluator
        EvaluatorBuilder.new(logger).build
      end

      def make_user_matching_clause(user, attr = :key)
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
