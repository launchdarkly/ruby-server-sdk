require "ldclient-rb/impl/model/feature_flag"
require "ldclient-rb/impl/model/preprocessed_data"
require "ldclient-rb/impl/model/segment"

module LaunchDarkly
  module Impl
    module Model
      # Abstraction of deserializing a feature flag or segment that was read from a data store or
      # received from LaunchDarkly.
      #
      # @param kind [Hash] normally either FEATURES or SEGMENTS
      # @param input [object] a JSON string or a parsed hash (or a data model object, in which case
      #  we'll just return the original object)
      # @param logger [Logger|nil] logs warnings if there are any data validation problems
      # @return [Object] the flag or segment (or, for an unknown data kind, the data as a hash)
      def self.deserialize(kind, input, logger = nil)
        return nil if input.nil?
        return input if !input.is_a?(String) && !input.is_a?(Hash)
        data = input.is_a?(Hash) ? input : JSON.parse(input, symbolize_names: true)
        case kind
        when FEATURES
          FeatureFlag.new(data, logger)
        when SEGMENTS
          Segment.new(data, logger)
        else
          data
        end
      end

      # Abstraction of serializing a feature flag or segment that will be written to a data store.
      # Currently we just call to_json.
      def self.serialize(kind, item)
        item.to_json
      end

      # Translates a { flags: ..., segments: ... } object received from LaunchDarkly to the data store format.
      def self.make_all_store_data(received_data, logger = nil)
        return {
          FEATURES => (received_data[:flags] || {}).transform_values { |data| FeatureFlag.new(data, logger) },
          SEGMENTS => (received_data[:segments] || {}).transform_values { |data| Segment.new(data, logger) }
        }
      end
    end
  end
end
