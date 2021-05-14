require "spec_helper"

describe LaunchDarkly::Impl::EventFactory do
  subject { LaunchDarkly::Impl::EventFactory }

  describe "#new_eval_event" do
    let(:event_factory_without_reason) { subject.new(false) }
    let(:user) { { 'key': 'userA' } }
    let(:rule_with_experiment_rollout) { 
      { id: 'ruleid',
        clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
        trackEvents: false,
        rollout: { kind: 'experiment', salt: '', variations: [ { weight: 100000, variation: 0, untracked: false } ] }
      }
    }

    let(:rule_with_rollout) { 
      { id: 'ruleid',
        trackEvents: false,
        clauses: [{ attribute: 'key', op: 'in', values: ['userkey'] }],
        rollout: { salt: '', variations: [ { weight: 100000, variation: 0, untracked: false } ] }
      }
    }

    let(:fallthrough_with_rollout) {
      { rollout: { kind: 'rollout', salt: '', variations: [ { weight: 100000, variation: 0, untracked: false } ], trackEventsFallthrough: false } }
    }

    let(:rule_reason) { LaunchDarkly::EvaluationReason::rule_match(0, 'ruleid') }
    let(:rule_reason_with_experiment) { LaunchDarkly::EvaluationReason::rule_match(0, 'ruleid', true) }
    let(:fallthrough_reason) { LaunchDarkly::EvaluationReason::fallthrough }
    let(:fallthrough_reason_with_experiment) { LaunchDarkly::EvaluationReason::fallthrough(true) }

    context "in_experiment is true" do
      it "sets the reason and trackevents: true for rules" do
        flag = createFlag('rule', rule_with_experiment_rollout)
        detail = LaunchDarkly::EvaluationDetail.new(true, 0, rule_reason_with_experiment)
        r = subject.new(false).new_eval_event(flag, user, detail, nil, nil)
        expect(r[:trackEvents]).to eql(true)
        expect(r[:reason].to_s).to eql("RULE_MATCH(0,ruleid,true)")
      end

      it "sets the reason and trackevents: true for the fallthrough" do
        fallthrough_with_rollout[:kind] = 'experiment'
        flag = createFlag('fallthrough', fallthrough_with_rollout)
        detail = LaunchDarkly::EvaluationDetail.new(true, 0, fallthrough_reason_with_experiment)
        r = subject.new(false).new_eval_event(flag, user, detail, nil, nil)
        expect(r[:trackEvents]).to eql(true)
        expect(r[:reason].to_s).to eql("FALLTHROUGH(true)")
      end
    end

    context "in_experiment is false" do
      it "sets the reason & trackEvents: true if rule has trackEvents set to true" do
        rule_with_rollout[:trackEvents] = true
        flag = createFlag('rule', rule_with_rollout)
        detail = LaunchDarkly::EvaluationDetail.new(true, 0, rule_reason)
        r = subject.new(false).new_eval_event(flag, user, detail, nil, nil)
        expect(r[:trackEvents]).to eql(true)
        expect(r[:reason].to_s).to eql("RULE_MATCH(0,ruleid)")
      end

      it "sets the reason & trackEvents: true if fallthrough has trackEventsFallthrough set to true" do
        flag = createFlag('fallthrough', fallthrough_with_rollout)
        flag[:trackEventsFallthrough] = true
        detail = LaunchDarkly::EvaluationDetail.new(true, 0, fallthrough_reason)
        r = subject.new(false).new_eval_event(flag, user, detail, nil, nil)
        expect(r[:trackEvents]).to eql(true)
        expect(r[:reason].to_s).to eql("FALLTHROUGH")
      end

      it "doesn't set the reason & trackEvents if rule has trackEvents set to false" do
        flag = createFlag('rule', rule_with_rollout)
        detail = LaunchDarkly::EvaluationDetail.new(true, 0, rule_reason)
        r = subject.new(false).new_eval_event(flag, user, detail, nil, nil)
        expect(r[:trackEvents]).to be_nil
        expect(r[:reason]).to be_nil
      end

      it "doesn't set the reason & trackEvents if fallthrough has trackEventsFallthrough set to false" do
        flag = createFlag('fallthrough', fallthrough_with_rollout)
        detail = LaunchDarkly::EvaluationDetail.new(true, 0, fallthrough_reason)
        r = subject.new(false).new_eval_event(flag, user, detail, nil, nil)
        expect(r[:trackEvents]).to be_nil
        expect(r[:reason]).to be_nil
      end

      it "sets trackEvents true and doesn't set the reason if flag[:trackEvents] = true" do
        flag = createFlag('fallthrough', fallthrough_with_rollout)
        flag[:trackEvents] = true
        detail = LaunchDarkly::EvaluationDetail.new(true, 0, fallthrough_reason)
        r = subject.new(false).new_eval_event(flag, user, detail, nil, nil)
        expect(r[:trackEvents]).to eql(true)
        expect(r[:reason]).to be_nil
      end
    end
  end

  def createFlag(kind, rule)
    if kind == 'rule'
      { key: 'feature', on: true, rules: [rule], fallthrough: { variation: 0 }, variations: [ false, true ] }
    elsif kind == 'fallthrough'
      { key: 'feature', on: true, fallthrough: rule, variations: [ false, true ] }
    else
      { key: 'feature', on: true, fallthrough: { variation: 0 }, variations: [ false, true ] }
    end
  end
end