# frozen_string_literal: true

require "ldclient-rb/impl/data_store"

require "concurrent/atomics"

module LaunchDarkly
  module Impl
    #
    # The flag and segment override layer. The layer is a runtime-mutable collection of flag and
    # segment definitions, supplied by an override source. Those definitions take precedence over
    # LaunchDarkly data at evaluation time.
    #
    # @private
    #
    module Overrides
      #
      # A thread-safe store of override entries, replaced as a whole on each update from an
      # override source. Reads are lock-free: the contents are an immutable hash held in an
      # atomic reference and swapped on update, so the layer holds exactly one snapshot at any
      # instant.
      #
      class Layer
        EMPTY_CONTENTS = {
          DataStore::FEATURES => {}.freeze,
          DataStore::SEGMENTS => {}.freeze,
        }.freeze
        private_constant :EMPTY_CONTENTS

        def initialize
          @contents = Concurrent::AtomicReference.new(EMPTY_CONTENTS)
        end

        #
        # Atomically replaces the entire layer contents. Empty hashes clear the layer.
        #
        # Each flag or segment is stored as a marked shallow copy. The copy shares its data with the
        # caller's object, and the layer never writes to it. The caller's object is never marked.
        #
        # @param flags [Hash{Symbol => LaunchDarkly::Impl::Model::FeatureFlag}]
        # @param segments [Hash{Symbol => LaunchDarkly::Impl::Model::Segment}]
        # @return [Array(Hash, Hash)] the previous and the new contents, keyed by data kind. The
        #   returned hashes must not be modified.
        #
        def set_all(flags, segments)
          replacement = {
            DataStore::FEATURES => flags.transform_values(&:as_override).freeze,
            DataStore::SEGMENTS => segments.transform_values(&:as_override).freeze,
          }.freeze
          previous = @contents.get_and_set(replacement)
          [previous, replacement]
        end

        #
        # Returns the override entry for a key, or nil.
        #
        # @param kind [LaunchDarkly::Impl::DataStore::DataKind]
        # @param key [String, Symbol]
        # @return [Object, nil]
        #
        def get(kind, key)
          items = @contents.get[kind]
          return nil if items.nil?

          items[key.to_sym]
        end

        #
        # Returns the entries of the given kind. The returned hash must not be modified.
        #
        # @param kind [LaunchDarkly::Impl::DataStore::DataKind]
        # @return [Hash{Symbol => Object}]
        #
        def all(kind)
          @contents.get[kind] || {}
        end

        #
        # Returns the current contents, keyed by data kind. The returned hash must not be modified.
        #
        # @return [Hash]
        #
        def contents
          @contents.get
        end

        #
        # Returns true if the layer contains no entries.
        #
        # @return [Boolean]
        #
        def empty?
          @contents.get.each_value.all?(&:empty?)
        end
      end
    end
  end
end
