require "ldclient-rb/impl/model/feature_flag"
require "ldclient-rb/impl/model/preprocessed_data"
require "ldclient-rb/impl/model/segment"

# General implementation notes about the data model classes in LaunchDarkly::Impl::Model--
#
# As soon as we receive flag/segment JSON data from LaunchDarkly (or, read it from a database), we
# transform it into the model classes FeatureFlag, Segment, etc. The constructor of each of these
# classes takes a hash (the parsed JSON), and transforms it into an internal representation that
# is more efficient for evaluations.
#
# Validation works as follows:
# - A property value that is of the correct type, but is invalid for other reasons (for example,
# if a flag rule refers to variation index 5, but there are only 2 variations in the flag), does
# not prevent the flag from being parsed and stored. It does cause a warning to be logged, if a
# logger was passed to the constructor.
# - If a value is completely invalid for the schema, the constructor may throw an
# exception, causing the whole data set to be rejected. This is consistent with the behavior of
# the strongly-typed SDKs.
#
# Currently, the model classes also retain the original hash of the parsed JSON. This is because
# we may need to re-serialize them to JSON, and building the JSON on the fly would be very
# inefficient, so each model class has a to_json method that just returns the same Hash. If we
# are able in the future to either use a custom streaming serializer, or pass the JSON data
# straight through from LaunchDarkly to a database instead of re-serializing, we could stop
# retaining this data.

module LaunchDarkly
  module Impl
    module Model
      # Abstraction of deserializing a feature flag or segment that was read from a data store or
      # received from LaunchDarkly.
      #
      # SDK code outside of Impl::Model should use this method instead of calling the model class
      # constructors directly, so as not to rely on implementation details.
      #
      # @param kind [Hash] normally either FEATURES or SEGMENTS
      # @param input [object] a JSON string or a parsed hash (or a data model object, in which case
      #  we'll just return the original object)
      # @param logger [Logger|nil] logs errors if there are any data validation problems
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
      # Currently we just call to_json, but SDK code outside of Impl::Model should use this method
      # instead of to_json, so as not to rely on implementation details.
      def self.serialize(kind, item)
        item.to_json
      end

      # Translates a { flags: ..., segments: ... } object received from LaunchDarkly to the data store format.
      def self.make_all_store_data(received_data, logger = nil)
        {
          FEATURES => (received_data[:flags] || {}).transform_values { |data| FeatureFlag.new(data, logger) },
          SEGMENTS => (received_data[:segments] || {}).transform_values { |data| Segment.new(data, logger) },
        }
      end
    end
  end
end
