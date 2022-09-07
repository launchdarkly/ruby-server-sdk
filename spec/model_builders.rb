require "ldclient-rb/impl/model/preprocessed_data"
require "json"

def clone_json_object(o)
  JSON.parse(o.to_json, symbolize_names: true)
end

class DataItemFactory
  def initialize(with_preprocessing)
    @with_preprocessing = with_preprocessing
  end

  def flag(flag_data)
    @with_preprocessing ? preprocessed_flag(flag_data) : flag_data
  end

  def segment(segment_data)
    @with_preprocessing ? preprocessed_segment(segment_data) : segment_data
  end

  def boolean_flag_with_rules(rules)
    flag({ key: 'feature', on: true, rules: rules, fallthrough: { variation: 0 }, variations: [ false, true ] })
  end

  def boolean_flag_with_clauses(clauses)
    flag(boolean_flag_with_rules([{ id: 'ruleid', clauses: clauses, variation: 1 }]))
  end

  attr_reader :with_preprocessing

  private def preprocessed_flag(o)
    ret = clone_json_object(o)
    LaunchDarkly::Impl::DataModelPreprocessing::Preprocessor.new().preprocess_flag!(ret)
    ret
  end

  private def preprocessed_segment(o)
    ret = clone_json_object(o)
    LaunchDarkly::Impl::DataModelPreprocessing::Preprocessor.new().preprocess_segment!(ret)
    ret
  end
end

class FlagBuilder
  def initialize(key)
    @flag = {
      key: key,
      version: 1,
      variations: [ false ],
      rules: []
    }
  end

  def build
    DataItemFactory.new(true).flag(@flag)
  end

  def version(value)
    @flag[:version] = value
    self
  end

  def variations(*values)
    @flag[:variations] = values
    self
  end

  def on(value)
    @flag[:on] = value
    self
  end
  
  def rule(r)
    @flag[:rules].append(r.build)
    self
  end

  def off_with_value(value)
    @flag[:variations] = [ value ]
    @flag[:offVariation] = 0
    @flag[:on] = false
    self
  end

  def off_variation(value)
    @flag[:offVariation] = value
    self
  end

  def fallthrough_variation(value)
    @flag[:fallthrough] = { variation: value }
    self
  end

  def track_events(value)
    @flag[:trackEvents] = value
    self
  end

  def track_events_fallthrough(value)
    @flag[:trackEventsFallthrough] = value
    self
  end

  def debug_events_until_date(value)
    @flag[:debugEventsUntilDate] = value
    self
  end
end

class RuleBuilder
  def initialize()
    @rule = {
      id: "",
      variation: 0,
      clauses: []
    }
  end

  def build
    @rule.clone
  end

  def id(value)
    @rule[:id] = value
    self
  end

  def variation(value)
    @rule[:variation] = value
    self
  end

  def clause(c)
    @rule[:clauses].append(c)
    self
  end

  def track_events(value)
    @rule[:trackEvents] = value
    self
  end
end

class SegmentBuilder
  def initialize(key)
    @segment = {
      key: key,
      version: 1,
    included: [],
    excluded: []
    }
  end

  def build
    DataItemFactory.new(true).segment(@segment)
  end
  
  def included(*keys)
    @segment[:included] = keys
    self
  end

  def excluded(*keys)
    @segment[:excluded] = keys
    self
  end

  def unbounded(value)
    @segment[:unbounded] = value
    self
  end

  def generation(value)
    @segment[:generation] = value
    self
  end
end

class Clauses
  def self.match_segment(segment)
    {
      "attribute": "",
      "op": "segmentMatch",
      "values": [ segment.is_a?(Hash) ? segment[:key] : segment ]
    }
  end

  def self.match_user(user)
    {
      "attribute": "key",
      "op": "in",
      "values": [ user[:key] ]
    }
  end
end
