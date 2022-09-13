require "ldclient-rb/impl/big_segments"

require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    evaluator_tests_with_and_without_preprocessing "Evaluator (big segments)" do |desc, factory|
      describe "#{desc} - evaluate", :evaluator_spec_base => true do
        it "segment is not matched if there is no way to query it" do
          segment = factory.segment({
            key: 'test',
            included: [ user[:key] ],  # included should be ignored for a big segment
            version: 1,
            unbounded: true,
            generation: 1
          })
          e = EvaluatorBuilder.new(logger).
            with_segment(segment).
            build
          flag = factory.boolean_flag_with_clauses([make_segment_match_clause(segment)])
          result = e.evaluate(flag, user)
          expect(result.detail.value).to be false
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::NOT_CONFIGURED)
        end

        it "segment with no generation is not matched" do
          segment = factory.segment({
            key: 'test',
            included: [ user[:key] ],  # included should be ignored for a big segment
            version: 1,
            unbounded: true,
          })
          e = EvaluatorBuilder.new(logger).
            with_segment(segment).
            build
          flag = factory.boolean_flag_with_clauses([make_segment_match_clause(segment)])
          result = e.evaluate(flag, user)
          expect(result.detail.value).to be false
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::NOT_CONFIGURED)
        end

        it "matched with include" do
          segment = factory.segment({
            key: 'test',
            version: 1,
            unbounded: true,
            generation: 2,
          })
          e = EvaluatorBuilder.new(logger).
            with_segment(segment).
            with_big_segment_for_user(user, segment, true).
            build
          flag = factory.boolean_flag_with_clauses([make_segment_match_clause(segment)])
          result = e.evaluate(flag, user)
          expect(result.detail.value).to be true
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::HEALTHY)
        end

        it "matched with rule" do
          segment = factory.segment({
            key: 'test',
            version: 1,
            unbounded: true,
            generation: 2,
            rules: [
              { clauses: [ make_user_matching_clause(user) ] }
            ],
          })
          e = EvaluatorBuilder.new(logger).
            with_segment(segment).
            with_big_segment_for_user(user, segment, nil).
            build
          flag = factory.boolean_flag_with_clauses([make_segment_match_clause(segment)])
          result = e.evaluate(flag, user)
          expect(result.detail.value).to be true
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::HEALTHY)
        end

        it "unmatched by exclude regardless of rule" do
          segment = factory.segment({
            key: 'test',
            version: 1,
            unbounded: true,
            generation: 2,
            rules: [
              { clauses: [ make_user_matching_clause(user) ] }
            ],
          })
          e = EvaluatorBuilder.new(logger).
            with_segment(segment).
            with_big_segment_for_user(user, segment, false).
            build
          flag = factory.boolean_flag_with_clauses([make_segment_match_clause(segment)])
          result = e.evaluate(flag, user)
          expect(result.detail.value).to be false
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::HEALTHY)
        end

        it "status is returned from provider" do
          segment = factory.segment({
            key: 'test',
            version: 1,
            unbounded: true,
            generation: 2,
          })
          e = EvaluatorBuilder.new(logger).
            with_segment(segment).
            with_big_segment_for_user(user, segment, true).
            with_big_segments_status(BigSegmentsStatus::STALE).
            build
          flag = factory.boolean_flag_with_clauses([make_segment_match_clause(segment)])
          result = e.evaluate(flag, user)
          expect(result.detail.value).to be true
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::STALE)
        end

        it "queries state only once per user even if flag references multiple segments" do
          segment1 = factory.segment({
            key: 'segmentkey1',
            version: 1,
            unbounded: true,
            generation: 2,
          })
          segment2 = factory.segment({
            key: 'segmentkey2',
            version: 1,
            unbounded: true,
            generation: 3,
          })
          flag = factory.flag({
            key: 'key',
            on: true,
            fallthrough: { variation: 0 },
            variations: [ false, true ],
            rules: [
              { variation: 1, clauses: [ make_segment_match_clause(segment1) ]},
              { variation: 1, clauses: [ make_segment_match_clause(segment2) ]}
            ],
          })
      
          queries = []
          e = EvaluatorBuilder.new(logger).
            with_segment(segment1).with_segment(segment2).
            with_big_segment_for_user(user, segment2, true).
            record_big_segments_queries(queries).
            build
          # The membership deliberately does not include segment1, because we want the first rule to be
          # a non-match so that it will continue on and check segment2 as well.
      
          result = e.evaluate(flag, user)
          expect(result.detail.value).to be true
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::HEALTHY)

          expect(queries).to eq([ user[:key] ])
        end
      end
    end
  end
end
