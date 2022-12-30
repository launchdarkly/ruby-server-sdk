require "ldclient-rb/impl/model/feature_flag"
require "ldclient-rb/impl/model/segment"
require "json"

class Flags
  def self.from_hash(data)
    LaunchDarkly::Impl::Model.deserialize(LaunchDarkly::FEATURES, data)
  end

  def self.boolean_flag_with_rules(*rules)
    builder = FlagBuilder.new("feature").on(true).variations(false, true).fallthrough_variation(0)
    rules.each { |r| builder.rule(r) }
    builder.build
  end

  def self.boolean_flag_with_clauses(*clauses)
    self.boolean_flag_with_rules({ id: 'ruleid', clauses: clauses, variation: 1 })
  end
end

class Segments
  def self.from_hash(data)
    LaunchDarkly::Impl::Model.deserialize(LaunchDarkly::SEGMENTS, data)
  end
end

class Clauses
  def self.match_segment(segment)
    {
      "attribute": "",
      "op": "segmentMatch",
      "values": [ segment.is_a?(String) ? segment : segment[:key] ],
    }
  end

  def self.match_context(context, attr = :key)
    {
      "attribute": attr.to_s,
      "op": "in",
      "values": [ context.get_value(attr) ],
      "contextKind": context.individual_context(0).kind,
    }
  end
end

class FlagBuilder
  def initialize(key)
    @flag = {
      key: key,
      version: 1,
      variations: [ false ],
      rules: [],
    }
  end

  def build
    Flags.from_hash(@flag)
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
    @flag[:rules].append(r.is_a?(RuleBuilder) ? r.build : r)
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
      clauses: [],
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

class SegmentRuleBuilder
  def initialize()
    @rule = {
      clauses: [],
    }
  end

  def build
    @rule.clone
  end

  def clause(c)
    @rule[:clauses].append(c)
    self
  end
end

class SegmentBuilder
  def initialize(key)
    @segment = {
      key: key,
      version: 1,
      included: [],
      excluded: [],
      includedContexts: [],
      excludedContexts: [],
      rules: [],
    }
  end

  def build
    Segments.from_hash(@segment)
  end

  def version(value)
    @segment[:version] = value
    self
  end

  def included(*keys)
    @segment[:included] = keys
    self
  end

  def included_contexts(kind, *keys)
    @segment[:includedContexts].append({ contextKind: kind, values: keys })
    self
  end

  def excluded_contexts(kind, *keys)
    @segment[:excludedContexts].append({ contextKind: kind, values: keys })
    self
  end

  def excluded(*keys)
    @segment[:excluded] = keys
    self
  end

  def rule(r)
    @segment[:rules].append(r.is_a?(SegmentRuleBuilder) ? r.build : r)
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

class DataSetBuilder
  def initialize
    @flags = {}
    @segments = {}
  end

  def flag(data)
    f = LaunchDarkly::Impl::Model.deserialize(LaunchDarkly::FEATURES, data)
    @flags[f.key.to_sym] = f
    self
  end

  def segment(data)
    s = LaunchDarkly::Impl::Model.deserialize(LaunchDarkly::SEGMENTS, data)
    @segments[s.key.to_sym] = s
    self
  end

  def to_store_data
    {
      LaunchDarkly::FEATURES => @flags,
      LaunchDarkly::SEGMENTS => @segments,
    }
  end

  def to_hash
    {
      flags: @flags,
      segments: @segments,
    }
  end

  def to_json(*)
    to_hash.to_json
  end
end
