require "spec_helper"

module LaunchDarkly
  describe "EvaluationDetail" do
    subject { EvaluationDetail }

    it "sets properties" do
      expect(EvaluationDetail.new("x", 0, EvaluationReason::off).value).to eq "x"
      expect(EvaluationDetail.new("x", 0, EvaluationReason::off).variation_index).to eq 0
      expect(EvaluationDetail.new("x", 0, EvaluationReason::off).reason).to eq EvaluationReason::off
    end

    it "checks parameter types" do
      expect { EvaluationDetail.new(nil, nil, EvaluationReason::off) }.not_to raise_error
      expect { EvaluationDetail.new(nil, 0, EvaluationReason::off) }.not_to raise_error
      expect { EvaluationDetail.new(nil, "x", EvaluationReason::off) }.to raise_error(ArgumentError)
      expect { EvaluationDetail.new(nil, 0, { kind: "OFF" }) }.to raise_error(ArgumentError)
      expect { EvaluationDetail.new(nil, 0, nil) }.to raise_error(ArgumentError)
    end

    it "equality test" do
      expect(EvaluationDetail.new("x", 0, EvaluationReason::off)).to eq EvaluationDetail.new("x", 0, EvaluationReason::off)
      expect(EvaluationDetail.new("x", 0, EvaluationReason::off)).not_to eq EvaluationDetail.new("y", 0, EvaluationReason::off)
      expect(EvaluationDetail.new("x", 0, EvaluationReason::off)).not_to eq EvaluationDetail.new("x", 1, EvaluationReason::off)
      expect(EvaluationDetail.new("x", 0, EvaluationReason::off)).not_to eq EvaluationDetail.new("x", 0, EvaluationReason::fallthrough)
    end
  end

  describe "EvaluationReason" do
    subject { EvaluationReason }

    values = [
      [ EvaluationReason::off, EvaluationReason::OFF, { "kind" => "OFF" }, "OFF", nil ],
      [ EvaluationReason::fallthrough, EvaluationReason::FALLTHROUGH,
        { "kind" => "FALLTHROUGH" }, "FALLTHROUGH", nil ],
      [ EvaluationReason::target_match, EvaluationReason::TARGET_MATCH,
        { "kind" => "TARGET_MATCH" }, "TARGET_MATCH", nil ],
      [ EvaluationReason::rule_match(1, "x"), EvaluationReason::RULE_MATCH,
        { "kind" => "RULE_MATCH", "ruleIndex" => 1, "ruleId" => "x" }, "RULE_MATCH(1,x)",
        [ EvaluationReason::rule_match(2, "x"), EvaluationReason::rule_match(1, "y") ] ],
      [ EvaluationReason::prerequisite_failed("x"), EvaluationReason::PREREQUISITE_FAILED,
        { "kind" => "PREREQUISITE_FAILED", "prerequisiteKey" => "x" }, "PREREQUISITE_FAILED(x)" ],
      [ EvaluationReason::error(EvaluationReason::ERROR_FLAG_NOT_FOUND), EvaluationReason::ERROR,
        { "kind" => "ERROR", "errorKind" => "FLAG_NOT_FOUND" }, "ERROR(FLAG_NOT_FOUND)" ],
      [ EvaluationReason::fallthrough().with_big_segments_status(BigSegmentsStatus::HEALTHY), EvaluationReason::FALLTHROUGH,
        { "kind" => "FALLTHROUGH", "bigSegmentsStatus" => "HEALTHY" }, "FALLTHROUGH",
        [ EvaluationReason::fallthrough ] ],
      [ EvaluationReason::off.with_override_affected(true), EvaluationReason::OFF,
        { "kind" => "OFF", "overrideAffected" => true }, "OFF",
        [ EvaluationReason::off ] ],
      [ EvaluationReason::rule_match(1, "x").with_big_segments_status(BigSegmentsStatus::STALE).with_override_affected(true),
        EvaluationReason::RULE_MATCH,
        { "kind" => "RULE_MATCH", "ruleIndex" => 1, "ruleId" => "x", "bigSegmentsStatus" => "STALE", "overrideAffected" => true },
        "RULE_MATCH(1,x)",
        [ EvaluationReason::rule_match(1, "x"), EvaluationReason::rule_match(1, "x").with_override_affected(true) ] ],
      [ EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG).with_override_affected(true), EvaluationReason::ERROR,
        { "kind" => "ERROR", "errorKind" => "MALFORMED_FLAG", "overrideAffected" => true }, "ERROR(MALFORMED_FLAG)",
        [ EvaluationReason::error(EvaluationReason::ERROR_MALFORMED_FLAG) ] ],
    ]
    values.each_index do |i|
      params = values[i]
      reason = params[0]
      kind = params[1]
      json_rep = params[2]
      brief_str = params[3]
      unequal_values = params[4]

      describe "reason #{reason.kind}" do
        it "has correct kind" do
          expect(reason.kind).to eq kind
        end

        it "equality to self" do
          expect(reason).to eq reason
        end

        it "inequality to others" do
          values.each_index do |j|
            if i != j
              expect(reason).not_to eq values[j][0]
            end
          end
          unless unequal_values.nil?
            unequal_values.each do |v|
              expect(reason).not_to eq v
            end
          end
        end

        it "JSON representation" do
          expect(JSON.parse(reason.as_json.to_json)).to eq json_rep
          expect(JSON.parse(reason.to_json)).to eq json_rep
        end

        it "brief representation" do
          expect(reason.inspect).to eq brief_str
          expect(reason.to_s).to eq brief_str
        end
      end
    end

    it "reuses singleton reasons" do
      expect(EvaluationReason::off).to be EvaluationReason::off
      expect(EvaluationReason::fallthrough).to be EvaluationReason::fallthrough
      expect(EvaluationReason::target_match).to be EvaluationReason::target_match
      expect(EvaluationReason::rule_match(1, 'x')).not_to be EvaluationReason::rule_match(1, 'x')
      expect(EvaluationReason::prerequisite_failed('x')).not_to be EvaluationReason::prerequisite_failed('x')
      errors = [ EvaluationReason::ERROR_CLIENT_NOT_READY, EvaluationReason::ERROR_FLAG_NOT_FOUND,
        EvaluationReason::ERROR_MALFORMED_FLAG, EvaluationReason::ERROR_USER_NOT_SPECIFIED, EvaluationReason::ERROR_EXCEPTION ]
      errors.each do |e|
        expect(EvaluationReason::error(e)).to be EvaluationReason::error(e)
      end
    end

    describe "override affected indicator" do
      it "is false by default" do
        expect(EvaluationReason::off.override_affected).to be false
        expect(EvaluationReason::rule_match(0, "x").override_affected).to be false
        expect(EvaluationReason::error(EvaluationReason::ERROR_FLAG_NOT_FOUND).override_affected).to be false
      end

      it "returns the same instance when the indicator does not change" do
        expect(EvaluationReason::off.with_override_affected(false)).to be EvaluationReason::off
        marked = EvaluationReason::off.with_override_affected(true)
        expect(marked.with_override_affected(true)).to be marked
      end

      it "returns a new instance when the indicator changes and keeps the other properties" do
        base = EvaluationReason::rule_match(2, "y", true).with_big_segments_status(BigSegmentsStatus::HEALTHY)
        marked = base.with_override_affected(true)

        expect(marked).not_to be base
        expect(marked.override_affected).to be true
        expect(marked.kind).to eq EvaluationReason::RULE_MATCH
        expect(marked.rule_index).to eq 2
        expect(marked.rule_id).to eq "y"
        expect(marked.in_experiment).to be true
        expect(marked.big_segments_status).to eq BigSegmentsStatus::HEALTHY
        expect(marked).not_to eq base
        expect(marked.with_override_affected(false)).to eq base
      end

      it "coerces the indicator to a boolean" do
        expect(EvaluationReason::off.with_override_affected(nil)).to be EvaluationReason::off
        expect(EvaluationReason::off.with_override_affected("yes").override_affected).to be true
      end

      it "is omitted from the JSON representation when false" do
        expect(EvaluationReason::off.as_json).not_to have_key(:overrideAffected)
        expect(EvaluationReason::fallthrough(true).as_json).not_to have_key(:overrideAffected)
        expect(JSON.parse(EvaluationReason::off.to_json)).to eq({ "kind" => "OFF" })
      end

      it "is written as true in the JSON representation when set" do
        expect(EvaluationReason::fallthrough(true).with_override_affected(true).as_json).to eq(
          { kind: :FALLTHROUGH, inExperiment: true, overrideAffected: true })
      end

      it "is exposed through []" do
        expect(EvaluationReason::off[:overrideAffected]).to be false
        expect(EvaluationReason::off.with_override_affected(true)[:overrideAffected]).to be true
      end

      it "takes part in equality with a hash" do
        marked = EvaluationReason::off.with_override_affected(true)
        expect(marked == { kind: "OFF", overrideAffected: true }).to be true
        expect(marked == { kind: "OFF" }).to be false
        expect(EvaluationReason::off == { kind: "OFF" }).to be true
        expect(EvaluationReason::off == { kind: "OFF", overrideAffected: true }).to be false
      end

      it "keeps the indicator when the big segments status changes" do
        marked = EvaluationReason::off.with_override_affected(true).with_big_segments_status(BigSegmentsStatus::STALE)
        expect(marked.override_affected).to be true
        expect(marked.big_segments_status).to eq BigSegmentsStatus::STALE
      end
    end

    it "supports [] with JSON property names" do
      expect(EvaluationReason::off[:kind]).to eq "OFF"
      expect(EvaluationReason::off[:ruleIndex]).to be nil
      expect(EvaluationReason::off[:ruleId]).to be nil
      expect(EvaluationReason::off[:prerequisiteKey]).to be nil
      expect(EvaluationReason::off[:errorKind]).to be nil
      expect(EvaluationReason::rule_match(1, "x")[:ruleIndex]).to eq 1
      expect(EvaluationReason::rule_match(1, "x")[:ruleId]).to eq "x"
      expect(EvaluationReason::prerequisite_failed("x")[:prerequisiteKey]).to eq "x"
      expect(EvaluationReason::error(EvaluationReason::ERROR_FLAG_NOT_FOUND)[:errorKind]).to eq "FLAG_NOT_FOUND"
      expect(EvaluationReason::fallthrough().with_big_segments_status(BigSegmentsStatus::HEALTHY)[:bigSegmentsStatus]).to eq "HEALTHY"
    end

    it "freezes string properties" do
      rm = EvaluationReason::rule_match(1, "x")
      expect { rm.rule_id.upcase! }.to raise_error(RuntimeError)
      pf = EvaluationReason::prerequisite_failed("x")
      expect { pf.prerequisite_key.upcase! }.to raise_error(RuntimeError)
    end

    it "checks parameter types" do
      expect { EvaluationReason::rule_match(nil, "x") }.to raise_error(ArgumentError)
      expect { EvaluationReason::rule_match(true, "x") }.to raise_error(ArgumentError)
      expect { EvaluationReason::rule_match(1, nil) }.not_to raise_error # we allow nil rule_id for backward compatibility
      expect { EvaluationReason::rule_match(1, 9) }.to raise_error(ArgumentError)
      expect { EvaluationReason::prerequisite_failed(nil) }.to raise_error(ArgumentError)
      expect { EvaluationReason::prerequisite_failed(9) }.to raise_error(ArgumentError)
      expect { EvaluationReason::error(nil) }.to raise_error(ArgumentError)
      expect { EvaluationReason::error(9) }.to raise_error(ArgumentError)
    end
  end
end
