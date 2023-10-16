require "model_builders"
require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    describe "Evaluator (segments)" do
      describe "evaluate", :evaluator_spec_base => true do
        def test_segment_match(segment, context)
          clause = Clauses.match_segment(segment)
          flag = Flags.boolean_flag_with_clauses(clause)
          e = EvaluatorBuilder.new(logger).with_segment(segment).build
          e.evaluate(flag, context).detail.value
        end

        it "retrieves segment from segment store for segmentMatch operator" do
          segment = {
            key: 'segkey',
            included: [ 'userkey' ],
            version: 1,
            deleted: false,
          }
          e = EvaluatorBuilder.new(logger).with_segment(segment).build
          flag = Flags.boolean_flag_with_clauses(Clauses.match_segment(segment))
          expect(e.evaluate(flag, user_context).detail.value).to be true
        end

        it "falls through with no errors if referenced segment is not found" do
          e = EvaluatorBuilder.new(logger).with_unknown_segment('segkey').build
          clause = { attribute: '', op: 'segmentMatch', values: ['segkey'] }
          flag = Flags.boolean_flag_with_clauses(clause)
          expect(e.evaluate(flag, user_context).detail.value).to be false
        end

        it 'explicitly includes context' do
          segment = SegmentBuilder.new('segkey').included(user_context.key).build
          expect(test_segment_match(segment, user_context)).to be true
        end

        it 'explicitly includes a specific context kind' do
          org_context = LDContext::create({ key: "orgkey", kind: "org" })
          device_context = LDContext::create({ key: "devicekey", kind: "device" })
          multi_context = LDContext::create_multi([org_context, device_context])

          segment = SegmentBuilder.new('segkey')
            .included_contexts("org", "orgkey")
            .build

          expect(test_segment_match(segment, org_context)).to be true
          expect(test_segment_match(segment, device_context)).to be false
          expect(test_segment_match(segment, multi_context)).to be true
        end

        it 'explicitly excludes context' do
          segment = SegmentBuilder.new('segkey').excluded(user_context.key).build
          expect(test_segment_match(segment, user_context)).to be false
        end

        it 'explicitly excludes a specific context kind' do
          org_context = LDContext::create({ key: "orgkey", kind: "org" })
          device_context = LDContext::create({ key: "devicekey", kind: "device" })
          multi_context = LDContext::create_multi([org_context, device_context])

          org_clause = Clauses.match_context(org_context, :key)
          device_clause = Clauses.match_context(device_context, :key)
          segment = SegmentBuilder.new('segkey')
            .excluded_contexts("org", "orgkey")
            .rule({ clauses: [ org_clause ]})
            .rule({ clauses: [ device_clause ]})
            .build

          expect(test_segment_match(segment, org_context)).to be false
          expect(test_segment_match(segment, device_context)).to be true
          expect(test_segment_match(segment, multi_context)).to be false
        end

        it 'both includes and excludes context; include takes priority' do
          segment = SegmentBuilder.new('segkey').included(user_context.key).excluded(user_context.key).build
          expect(test_segment_match(segment, user_context)).to be true
        end

        it 'matches context by rule when weight is absent' do
          seg_clause = Clauses.match_context(user_context, :email)
          seg_rule = {
            clauses: [seg_clause ],
          }
          segment = SegmentBuilder.new('segkey').rule(seg_rule).build
          expect(test_segment_match(segment, user_context)).to be true
        end

        it 'matches context by rule when weight is nil' do
          seg_clause = Clauses.match_context(user_context, :email)
          seg_rule = {
            clauses: [seg_clause ],
            weight: nil,
          }
          segment = SegmentBuilder.new('segkey').rule(seg_rule).build
          expect(test_segment_match(segment, user_context)).to be true
        end

        it 'matches context with full rollout' do
          seg_clause = Clauses.match_context(user_context, :email)
          seg_rule = {
            clauses: [seg_clause ],
            weight: 100000,
          }
          segment = SegmentBuilder.new('segkey').rule(seg_rule).build
          expect(test_segment_match(segment, user_context)).to be true
        end

        it "doesn't match context with zero rollout" do
          seg_clause = Clauses.match_context(user_context, :email)
          seg_rule = {
            clauses: [seg_clause ],
            weight: 0,
          }
          segment = SegmentBuilder.new('segkey').rule(seg_rule).build
          expect(test_segment_match(segment, user_context)).to be false
        end

        it "matches context with multiple clauses" do
          seg_clause_1 = Clauses.match_context(user_context, :email)
          seg_clause_2 = Clauses.match_context(user_context, :name)
          seg_rule = {
            clauses: [seg_clause_1, seg_clause_2 ],
          }
          segment = SegmentBuilder.new('segkey').rule(seg_rule).build
          expect(test_segment_match(segment, user_context)).to be true
        end

        it "doesn't match context with multiple clauses if a clause doesn't match" do
          seg_clause_1 = Clauses.match_context(user_context, :email)
          seg_clause_2 = Clauses.match_context(user_context, :name)
          seg_clause_2[:values] = ['wrong' ]
          seg_rule = {
            clauses: [seg_clause_1, seg_clause_2 ],
          }
          segment = SegmentBuilder.new('segkey').rule(seg_rule).build
          expect(test_segment_match(segment, user_context)).to be false
        end

        (1..4).each do |depth|
          it "can handle segments referencing other segments" do
            context = LDContext.with_key("context")
            segments = []
            (0...depth).each do |i|
              builder = SegmentBuilder.new("segmentkey#{i}")
              if i == depth - 1
                builder.included(context.key)
              else
                clause = Clauses.match_segment("segmentkey#{i + 1}")
                builder.rule(
                  SegmentRuleBuilder.new.clause(clause)
                )
              end

              segments << builder.build
            end

            flag = Flags.boolean_flag_with_clauses(Clauses.match_segment("segmentkey0"))

            builder = EvaluatorBuilder.new(logger)
            segments.each { |segment| builder.with_segment(segment) }

            evaluator = builder.build
            result = evaluator.evaluate(flag, context)
            expect(result.detail.value).to be(true)

          end

          it "will detect cycles in segments" do
            context = LDContext.with_key("context")
            segments = []
            (0...depth).each do |i|
              clause = Clauses.match_segment("segmentkey#{(i + 1) % depth}")
              builder = SegmentBuilder.new("segmentkey#{i}")
              builder.rule(
                SegmentRuleBuilder.new.clause(clause)
              )

              segments << builder.build
            end

            flag = Flags.boolean_flag_with_clauses(Clauses.match_segment("segmentkey0"))

            builder = EvaluatorBuilder.new(logger)
            segments.each { |segment| builder.with_segment(segment) }

            evaluator = builder.build
            result = evaluator.evaluate(flag, context)
            reason = EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG)
            expect(result.detail.reason).to eq(reason)
          end
        end
      end
    end
  end
end
