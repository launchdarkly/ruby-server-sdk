require "spec_helper"
require "impl/evaluator_spec_base"

module LaunchDarkly
  module Impl
    describe "evaluate with override definitions", :evaluator_spec_base => true do
      let(:context) { LDContext.create({ key: "user-key", kind: "user" }) }
      let(:other_context) { LDContext.create({ key: "other-key", kind: "user" }) }

      # A flag that is off and serves one value, which is how a value-only override is expanded.
      def value_flag(key, value)
        Flags.from_hash({ key: key, version: 1, on: false, offVariation: 0, variations: [value] })
      end

      # A flag that is on and serves variation 1 unless a prerequisite fails.
      def flag_with_prerequisites(key, *prereq_keys)
        Flags.from_hash({
          key: key,
          version: 1,
          on: true,
          prerequisites: prereq_keys.map { |k| { key: k, variation: 1 } },
          fallthrough: { variation: 1 },
          offVariation: 0,
          variations: ["prereq-failed-#{key}", "value-#{key}"],
        })
      end

      # A flag that is on and serves variation 1.
      def on_flag(key)
        flag_with_prerequisites(key)
      end

      def segment_flag(key, segment_key, negate: false)
        Flags.from_hash({
          key: key,
          version: 1,
          on: true,
          rules: [{ id: "segment-rule", variation: 1,
                    clauses: [{ attribute: "", op: "segmentMatch", values: [segment_key], negate: negate }] }],
          fallthrough: { variation: 0 },
          offVariation: 0,
          variations: ["not-included", "included"],
        })
      end

      def segment_including(key, *user_keys)
        Segments.from_hash({ key: key, version: 1, included: user_keys })
      end

      def record_for(result, key)
        result.prereq_evals.detect { |r| r.prereq_flag.key == key }
      end

      it "marks an evaluation of a flag from the override store" do
        flag = value_flag("flag", "override-value").as_override
        e = EvaluatorBuilder.new(logger).build

        (result, state) = e.evaluate(flag, context)

        expect(result.override_affected).to be true
        expect(state.override_affected).to be true
        expect(result.detail.value).to eq "override-value"
        expect(result.detail.variation_index).to eq 0
        expect(result.detail.reason.kind).to eq EvaluationReason::OFF
        expect(result.detail.reason.override_affected).to be true
        expect(result.detail.reason.as_json).to eq({ kind: :OFF, overrideAffected: true })
      end

      it "does not mark an evaluation that read no override definition and keeps the shared detail instance" do
        flag = value_flag("flag", "ld-value")
        e = EvaluatorBuilder.new(logger).build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be false
        expect(result.detail).to be flag.off_result
        expect(result.detail.reason.override_affected).to be false
        expect(result.detail.reason.as_json).to eq({ kind: :OFF })
      end

      it "marks an evaluation whose prerequisite came from the override store, and marks the prerequisite's record" do
        flag = flag_with_prerequisites("flag", "prereq")
        prereq = on_flag("prereq").as_override
        e = EvaluatorBuilder.new(logger).with_flag(prereq).build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be true
        expect(result.detail.value).to eq "value-flag"
        expect(result.detail.reason).to eq EvaluationReason::fallthrough.with_override_affected(true)
        record = record_for(result, "prereq")
        expect(record.override_affected).to be true
        expect(record.detail.reason).to eq EvaluationReason::fallthrough.with_override_affected(true)
      end

      it "does not mark the record of an unaffected prerequisite inside a marked evaluation" do
        flag = flag_with_prerequisites("flag", "overridden-prereq", "plain-prereq")
        e = EvaluatorBuilder.new(logger)
          .with_flag(on_flag("overridden-prereq").as_override)
          .with_flag(on_flag("plain-prereq"))
          .build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be true
        expect(result.detail.reason.override_affected).to be true
        expect(record_for(result, "overridden-prereq").override_affected).to be true
        expect(record_for(result, "overridden-prereq").detail.reason.override_affected).to be true
        plain = record_for(result, "plain-prereq")
        expect(plain.override_affected).to be false
        expect(plain.detail.reason.override_affected).to be false
        expect(plain.detail.reason).to eq EvaluationReason::fallthrough
      end

      it "does not mark a prerequisite's record because the evaluated flag is an override" do
        flag = flag_with_prerequisites("flag", "prereq").as_override
        e = EvaluatorBuilder.new(logger).with_flag(on_flag("prereq")).build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be true
        record = record_for(result, "prereq")
        expect(record.override_affected).to be false
        expect(record.detail.reason.override_affected).to be false
      end

      it "propagates the marking upward through every level of prerequisites and not sideways" do
        # A depends on B and C. B depends on D, which is the only override. C uses segment S1.
        a = flag_with_prerequisites("a", "b", "c")
        b = flag_with_prerequisites("b", "d")
        c = segment_flag("c", "s1")
        d = on_flag("d").as_override
        s1 = segment_including("s1", context.key)
        e = EvaluatorBuilder.new(logger).with_flag(b).with_flag(c).with_flag(d).with_segment(s1).build

        (result, _) = e.evaluate(a, context)

        expect(result.override_affected).to be true
        expect(result.detail.reason.override_affected).to be true
        expect(record_for(result, "b").override_affected).to be true
        expect(record_for(result, "d").override_affected).to be true
        expect(record_for(result, "c").override_affected).to be false
        expect(record_for(result, "c").detail.reason.override_affected).to be false
      end

      it "marks an evaluation when a rule read a segment from the override store" do
        flag = segment_flag("flag", "seg")
        e = EvaluatorBuilder.new(logger).with_segment(segment_including("seg", context.key).as_override).build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be true
        expect(result.detail.value).to eq "included"
        expect(result.detail.reason).to eq EvaluationReason::rule_match(0, "segment-rule").with_override_affected(true)
      end

      it "marks an evaluation when an override segment was read but did not match" do
        flag = segment_flag("flag", "seg")
        e = EvaluatorBuilder.new(logger).with_segment(segment_including("seg", context.key).as_override).build

        (result, _) = e.evaluate(flag, other_context)

        expect(result.override_affected).to be true
        expect(result.detail.value).to eq "not-included"
        expect(result.detail.reason).to eq EvaluationReason::fallthrough.with_override_affected(true)
      end

      it "marks an evaluation when a negated clause read an override segment" do
        flag = segment_flag("flag", "seg", negate: true)
        e = EvaluatorBuilder.new(logger).with_segment(segment_including("seg", context.key).as_override).build

        (result, _) = e.evaluate(flag, other_context)

        expect(result.override_affected).to be true
        expect(result.detail.value).to eq "included"
      end

      it "marks an evaluation when a segment rule read another segment from the override store" do
        flag = segment_flag("flag", "outer")
        outer = Segments.from_hash({
          key: "outer",
          version: 1,
          rules: [{ clauses: [{ attribute: "", op: "segmentMatch", values: ["inner"] }] }],
        })
        inner = segment_including("inner", context.key).as_override
        e = EvaluatorBuilder.new(logger).with_segment(outer).with_segment(inner).build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be true
        expect(result.detail.value).to eq "included"
      end

      it "does not mark an evaluation that read only LaunchDarkly segments" do
        flag = segment_flag("flag", "seg")
        e = EvaluatorBuilder.new(logger).with_segment(segment_including("seg", context.key)).build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be false
        expect(result.detail.reason).to eq EvaluationReason::rule_match(0, "segment-rule")
      end

      it "does not mark an evaluation for a definition that could not be resolved" do
        flag = flag_with_prerequisites("flag", "missing")
        e = EvaluatorBuilder.new(logger).with_unknown_flag("missing").build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be false
        expect(result.detail.reason).to eq EvaluationReason::prerequisite_failed("missing")
      end

      it "marks a prerequisite-failed result when the failed prerequisite came from the override store" do
        flag = flag_with_prerequisites("flag", "prereq")
        prereq = value_flag("prereq", "off-value").as_override
        e = EvaluatorBuilder.new(logger).with_flag(prereq).build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be true
        expect(result.detail.value).to eq "prereq-failed-flag"
        expect(result.detail.reason).to eq EvaluationReason::prerequisite_failed("prereq").with_override_affected(true)
        expect(record_for(result, "prereq").override_affected).to be true
      end

      it "marks an error result for a malformed override definition" do
        flag = Flags.from_hash({ key: "flag", version: 1, on: true, variations: ["only"], fallthrough: { variation: 5 }, offVariation: 0 }).as_override
        e = EvaluatorBuilder.new(logger).build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be true
        expect(result.detail.value).to be_nil
        expect(result.detail.variation_index).to be_nil
        expect(result.detail.reason).to eq EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG).with_override_affected(true)
        expect(result.detail.reason.as_json).to eq({ kind: :ERROR, errorKind: :MALFORMED_FLAG, overrideAffected: true })
      end

      it "marks an error result when an override definition was read before the evaluation failed" do
        # The evaluated flag is not an override. Its override prerequisite refers back to it, which
        # ends the evaluation with an error. The prerequisite definition was read, so the result is marked.
        flag = flag_with_prerequisites("flag", "prereq")
        prereq = flag_with_prerequisites("prereq", "flag").as_override
        e = EvaluatorBuilder.new(logger).with_flag(prereq).with_flag(flag).build

        (result, _) = e.evaluate(flag, context)

        expect(result.detail.reason.kind).to eq EvaluationReason::ERROR
        expect(result.detail.reason.error_kind).to eq EvaluationReason::ERROR_MALFORMED_FLAG
        expect(result.override_affected).to be true
        expect(result.detail.reason.override_affected).to be true
      end

      it "keeps the marking of an override flag when its prerequisite evaluation fails" do
        # The evaluated flag is an override. Its plain prerequisite refers back to it, which ends the
        # evaluation with an error while the prerequisite is being evaluated. The flag's own marking
        # must survive that.
        flag = flag_with_prerequisites("flag", "prereq").as_override
        prereq = flag_with_prerequisites("prereq", "flag")
        e = EvaluatorBuilder.new(logger).with_flag(prereq).with_flag(flag).build

        (result, _) = e.evaluate(flag, context)

        expect(result.detail.reason.error_kind).to eq EvaluationReason::ERROR_MALFORMED_FLAG
        expect(result.override_affected).to be true
        expect(result.detail.reason.override_affected).to be true
      end

      it "keeps the marking from an override prerequisite when a deeper prerequisite evaluation fails" do
        # A depends on B, which is an override. B depends on C, which refers back to A. The marking
        # that B contributed must survive the error raised while C is being evaluated.
        a = flag_with_prerequisites("a", "b")
        b = flag_with_prerequisites("b", "c").as_override
        c = flag_with_prerequisites("c", "a")
        e = EvaluatorBuilder.new(logger).with_flag(a).with_flag(b).with_flag(c).build

        (result, _) = e.evaluate(a, context)

        expect(result.detail.reason.error_kind).to eq EvaluationReason::ERROR_MALFORMED_FLAG
        expect(result.override_affected).to be true
      end

      it "keeps the big segments status on a marked reason" do
        segment = Segments.from_hash({ key: "seg", version: 1, unbounded: true, generation: 1 }).as_override
        flag = segment_flag("flag", "seg")
        e = EvaluatorBuilder.new(logger).with_segment(segment).with_big_segment_for_context(context, segment, true).build

        (result, _) = e.evaluate(flag, context)

        expect(result.override_affected).to be true
        expect(result.detail.value).to eq "included"
        expect(result.detail.reason.big_segments_status).to eq BigSegmentsStatus::HEALTHY
        expect(result.detail.reason.override_affected).to be true
      end
    end
  end
end
