require "ldclient-rb/impl/model/clause"
require "ldclient-rb/impl/model/preprocessed_data"

# See serialization.rb for implementation notes on the data model classes.

module LaunchDarkly
  module Impl
    module Model
      class Segment
        # @param data [Hash]
        # @param logger [Logger|nil]
        def initialize(data, logger = nil)
          raise ArgumentError, "expected hash but got #{data.class}" unless data.is_a?(Hash)
          @data = data
          @key = data[:key]
          @version = data[:version]
          @deleted = !!data[:deleted]
          return if @deleted
          @included = data[:included] || []
          @excluded = data[:excluded] || []
          @included_contexts = (data[:includedContexts] || []).map do |target_data|
            SegmentTarget.new(target_data)
          end
          @excluded_contexts = (data[:excludedContexts] || []).map do |target_data|
            SegmentTarget.new(target_data)
          end
          @rules = (data[:rules] || []).map do |rule_data|
            SegmentRule.new(rule_data, logger)
          end
          @unbounded = !!data[:unbounded]
          @generation = data[:generation]
          @salt = data[:salt]
        end

        # @return [Hash]
        attr_reader :data
        # @return [String]
        attr_reader :key
        # @return [Integer]
        attr_reader :version
        # @return [Boolean]
        attr_reader :deleted
        # @return [Array<String>]
        attr_reader :included
        # @return [Array<String>]
        attr_reader :excluded
        # @return [Array<LaunchDarkly::Impl::Model::SegmentTarget>]
        attr_reader :included_contexts
        # @return [Array<LaunchDarkly::Impl::Model::SegmentTarget>]
        attr_reader :excluded_contexts
        # @return [Array<SegmentRule>]
        attr_reader :rules
        # @return [Boolean]
        attr_reader :unbounded
        # @return [Integer|nil]
        attr_reader :generation
        # @return [String]
        attr_reader :salt

        # This method allows us to read properties of the object as if it's just a hash. Currently this is
        # necessary because some data store logic is still written to expect hashes; we can remove it once
        # we migrate entirely to using attributes of the class.
        def [](key)
          @data[key]
        end

        def ==(other)
          other.is_a?(Segment) && other.data == self.data
        end

        def as_json(*) # parameter is unused, but may be passed if we're using the json gem
          @data
        end

        # Same as as_json, but converts the JSON structure into a string.
        def to_json(*a)
          as_json.to_json(a)
        end
      end

      class SegmentTarget
        def initialize(data)
          @data = data
          @context_kind = data[:contextKind]
          @values = data[:values] || []
        end

        # @return [Hash]
        attr_reader :data
        # @return [String]
        attr_reader :context_kind
        # @return [Array]
        attr_reader :values
      end

      class SegmentRule
        def initialize(data, logger)
          @data = data
          @clauses = (data[:clauses] || []).map do |clause_data|
            Clause.new(clause_data, logger)
          end
          @weight = data[:weight]
          @bucket_by = data[:bucketBy]
          @rollout_context_kind = data[:rolloutContextKind]
        end

        # @return [Hash]
        attr_reader :data
        # @return [Array<LaunchDarkly::Impl::Model::Clause>]
        attr_reader :clauses
        # @return [Integer|nil]
        attr_reader :weight
        # @return [String|nil]
        attr_reader :bucket_by
        # @return [String|nil]
        attr_reader :rollout_context_kind
      end

      # Clause is defined in its own file because clauses are used by both flags and segments
    end
  end
end
