require "ldclient-rb/impl/model/preprocessed_data"

module LaunchDarkly
  module Impl
    module Model
      # Abstraction of deserializing a feature flag or segment that was read from a data store or
      # received from LaunchDarkly.
      def self.deserialize(kind, json, logger = nil)
        return nil if json.nil?
        item = JSON.parse(json, symbolize_names: true)
        DataModelPreprocessing::Preprocessor.new(logger).preprocess_item!(kind, item)
        item
      end

      # Abstraction of serializing a feature flag or segment that will be written to a data store.
      # Currently we just call to_json.
      def self.serialize(kind, item)
        item.to_json
      end

      # Translates a { flags: ..., segments: ... } object received from LaunchDarkly to the data store format.
      def self.make_all_store_data(received_data, logger = nil)
        preprocessor = DataModelPreprocessing::Preprocessor.new(logger)
        flags = received_data[:flags]
        preprocessor.preprocess_all_items!(FEATURES, flags)
        segments = received_data[:segments]
        preprocessor.preprocess_all_items!(SEGMENTS, segments)
        { FEATURES => flags, SEGMENTS => segments }
      end
    end
  end
end
