require "ldclient-rb/impl/big_segments"
require "ldclient-rb/impl/model/serialization"

require "model_builders"
require "spec_helper"

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
        @flags[flag[:key]] = Model.deserialize(FEATURES, flag)
        self
      end

      def with_unknown_flag(key)
        @flags[key] = nil
        self
      end

      def with_segment(segment)
        @segments[segment[:key]] = Model.deserialize(SEGMENTS, segment)
        self
      end

      def with_unknown_segment(key)
        @segments[key] = nil
        self
      end

      def with_big_segment_for_context(context, segment, included)
        context_key = context.key
        @big_segment_memberships[context_key] = {} unless @big_segment_memberships.has_key?(context_key)
        @big_segment_memberships[context_key][Evaluator.make_big_segment_ref(segment)] = included
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
        raise "should not have requested flag #{key}" unless @flags.has_key?(key)
        @flags[key]
      end

      private def get_segment(key)
        raise "should not have requested segment #{key}" unless @segments.has_key?(key)
        @segments[key]
      end

      private def get_big_segments(user_key)
        raise "should not have requested big segments for #{user_key}" unless @big_segment_memberships.has_key?(user_key)
        @big_segments_queries << user_key
        BigSegmentMembershipResult.new(@big_segment_memberships[user_key], @big_segments_status)
      end
    end

    module EvaluatorSpecBase
      def user_context
        LDContext::create({
          key: "userkey",
          email: "test@example.com",
          name: "Bob",
        })
      end

      def logger
        ::Logger.new($stdout, level: ::Logger::FATAL)
      end

      def basic_evaluator
        EvaluatorBuilder.new(logger).build
      end
    end

    RSpec.configure { |c| c.include EvaluatorSpecBase, :evaluator_spec_base => true }
  end
end
