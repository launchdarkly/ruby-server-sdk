require "ldclient-rb/impl/big_segments"

require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    describe "Evaluator (big segments)" do
      describe "evaluate", :evaluator_spec_base => true do
        it "segment is not matched if there is no way to query it" do
          segment = Segments.from_hash({
            key: 'test',
            included: [user_context.key ], # included should be ignored for a big segment
            version: 1,
            unbounded: true,
            generation: 1,
          })
          e = EvaluatorBuilder.new(logger)
            .with_segment(segment)
            .build
          flag = Flags.boolean_flag_with_clauses(Clauses.match_segment(segment))
          result = e.evaluate(flag, user_context)
          expect(result.detail.value).to be false
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::NOT_CONFIGURED)
        end

        it "segment with no generation is not matched" do
          segment = Segments.from_hash({
            key: 'test',
            included: [user_context.key ], # included should be ignored for a big segment
            version: 1,
            unbounded: true,
          })
          e = EvaluatorBuilder.new(logger)
            .with_segment(segment)
            .build
          flag = Flags.boolean_flag_with_clauses(Clauses.match_segment(segment))
          result = e.evaluate(flag, user_context)
          expect(result.detail.value).to be false
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::NOT_CONFIGURED)
        end

        it "matched with include" do
          segment = Segments.from_hash({
            key: 'test',
            version: 1,
            unbounded: true,
            generation: 2,
          })
          e = EvaluatorBuilder.new(logger)
            .with_segment(segment)
            .with_big_segment_for_context(user_context, segment, true)
            .build
          flag = Flags.boolean_flag_with_clauses(Clauses.match_segment(segment))
          result = e.evaluate(flag, user_context)
          expect(result.detail.value).to be true
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::HEALTHY)
        end

        it "matched with rule" do
          segment = Segments.from_hash({
            key: 'test',
            version: 1,
            unbounded: true,
            generation: 2,
            rules: [
              { clauses: [ Clauses.match_context(user_context) ] },
            ],
          })
          e = EvaluatorBuilder.new(logger)
            .with_segment(segment)
            .with_big_segment_for_context(user_context, segment, nil)
            .build
          flag = Flags.boolean_flag_with_clauses(Clauses.match_segment(segment))
          result = e.evaluate(flag, user_context)
          expect(result.detail.value).to be true
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::HEALTHY)
        end

        it "unmatched by exclude regardless of rule" do
          segment = Segments.from_hash({
            key: 'test',
            version: 1,
            unbounded: true,
            generation: 2,
            rules: [
              { clauses: [ Clauses.match_context(user_context) ] },
            ],
          })
          e = EvaluatorBuilder.new(logger)
            .with_segment(segment)
            .with_big_segment_for_context(user_context, segment, false)
            .build
          flag = Flags.boolean_flag_with_clauses(Clauses.match_segment(segment))
          result = e.evaluate(flag, user_context)
          expect(result.detail.value).to be false
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::HEALTHY)
        end

        it "status is returned from provider" do
          segment = Segments.from_hash({
            key: 'test',
            version: 1,
            unbounded: true,
            generation: 2,
          })
          e = EvaluatorBuilder.new(logger)
            .with_segment(segment)
            .with_big_segment_for_context(user_context, segment, true)
            .with_big_segments_status(BigSegmentsStatus::STALE)
            .build
          flag = Flags.boolean_flag_with_clauses(Clauses.match_segment(segment))
          result = e.evaluate(flag, user_context)
          expect(result.detail.value).to be true
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::STALE)
        end

        it "queries state only once per user even if flag references multiple segments" do
          segment1 = Segments.from_hash({
            key: 'segmentkey1',
            version: 1,
            unbounded: true,
            generation: 2,
          })
          segment2 = Segments.from_hash({
            key: 'segmentkey2',
            version: 1,
            unbounded: true,
            generation: 3,
          })
          flag = Flags.from_hash({
            key: 'key',
            on: true,
            fallthrough: { variation: 0 },
            variations: [ false, true ],
            rules: [
              { variation: 1, clauses: [ Clauses.match_segment(segment1) ]},
              { variation: 1, clauses: [ Clauses.match_segment(segment2) ]},
            ],
          })

          queries = []
          e = EvaluatorBuilder.new(logger)
            .with_segment(segment1).with_segment(segment2)
            .with_big_segment_for_context(user_context, segment2, true)
            .record_big_segments_queries(queries)
            .build
          # The membership deliberately does not include segment1, because we want the first rule to be
          # a non-match so that it will continue on and check segment2 as well.

          result = e.evaluate(flag, user_context)
          expect(result.detail.value).to be true
          expect(result.detail.reason.big_segments_status).to be(BigSegmentsStatus::HEALTHY)

          expect(queries).to eq([user_context.key ])
        end
      end
    end
  end
end
