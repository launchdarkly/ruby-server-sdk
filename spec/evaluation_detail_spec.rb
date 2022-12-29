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
