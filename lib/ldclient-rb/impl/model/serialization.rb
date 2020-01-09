
module LaunchDarkly
  module Impl
    module Model
      # Abstraction of deserializing a feature flag or segment that was read from a data store or
      # received from LaunchDarkly.
      def self.deserialize(kind, json)
        return nil if json.nil?
        item = JSON.parse(json, symbolize_names: true)
        postprocess_item_after_deserializing!(kind, item)
        item
      end

      # Abstraction of serializing a feature flag or segment that will be written to a data store.
      # Currently we just call to_json.
      def self.serialize(kind, item)
        item.to_json
      end

      # Translates a { flags: ..., segments: ... } object received from LaunchDarkly to the data store format.
      def self.make_all_store_data(received_data)
        flags = received_data[:flags]
        postprocess_items_after_deserializing!(FEATURES, flags)
        segments = received_data[:segments]
        postprocess_items_after_deserializing!(SEGMENTS, segments)
        { FEATURES => flags, SEGMENTS => segments }
      end

      # Called after we have deserialized a model item from JSON (because we received it from LaunchDarkly,
      # or read it from a persistent data store). This allows us to precompute some derived attributes that
      # will never change during the lifetime of that item.
      def self.postprocess_item_after_deserializing!(kind, item)
        return if !item
        # Currently we are special-casing this for FEATURES; eventually it will be handled by delegating
        # to the "kind" object or the item class.
        if kind.eql? FEATURES
          # For feature flags, we precompute all possible parameterized EvaluationReason instances.
          prereqs = item[:prerequisites]
          if !prereqs.nil?
            prereqs.each do |prereq|
              prereq[:_reason] = EvaluationReason::prerequisite_failed(prereq[:key])
            end
          end
          rules = item[:rules]
          if !rules.nil?
            rules.each_index do |i|
              rule = rules[i]
              rule[:_reason] = EvaluationReason::rule_match(i, rule[:id])
            end
          end
        end
      end

      def self.postprocess_items_after_deserializing!(kind, items_map)
        return items_map if !items_map
        items_map.each do |key, item|
          postprocess_item_after_deserializing!(kind, item)
        end
      end
    end
  end
end
