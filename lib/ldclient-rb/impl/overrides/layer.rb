# frozen_string_literal: true

require "ldclient-rb/impl/data_store"
require "ldclient-rb/impl/dependency_tracker"

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
      # Each snapshot also carries the dependency graph of its entries. The store consults it so
      # that a LaunchDarkly change to a prerequisite or a segment also notifies the override
      # entries that depend on it.
      #
      class Layer
        EMPTY_CONTENTS = {
          DataStore::FEATURES => {}.freeze,
          DataStore::SEGMENTS => {}.freeze,
        }.freeze
        private_constant :EMPTY_CONTENTS

        # The layer contents keyed by data kind, with the dependency graph of those entries.
        Snapshot = Struct.new(:contents, :dependencies)
        private_constant :Snapshot

        def initialize
          @snapshot = Concurrent::AtomicReference.new(Snapshot.new(EMPTY_CONTENTS, DependencyTracker.new).freeze)
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
          dependencies = DependencyTracker.new
          replacement.each do |kind, items|
            items.each do |key, item|
              # The graph keys items by string, the form in which the data model names
              # prerequisites and segments.
              dependencies.update_dependencies_from(kind, key.to_s, item)
            rescue StandardError
              # An entry whose dependency fields cannot be read contributes no edges. It is still
              # served, and the remaining entries are still tracked.
            end
          end
          previous = @snapshot.get_and_set(Snapshot.new(replacement, dependencies).freeze)
          [previous.contents, replacement]
        end

        #
        # Adds the given item and every override entry that directly or indirectly depends on it
        # to the set. The item itself need not be an override entry: a LaunchDarkly flag or
        # segment that an override entry references is a valid starting point. Items are
        # `{ kind:, key: }` hashes. The key given may be a string or a symbol; the items added
        # carry string keys.
        #
        # @param items_out [Set<Hash>]
        # @param item [Hash] `{ kind:, key: }`
        # @return [void]
        #
        def add_affected_items(items_out, item)
          @snapshot.get.dependencies.add_affected_items(items_out, { kind: item[:kind], key: item[:key].to_s })
        end

        #
        # Returns the override entry for a key, or nil.
        #
        # @param kind [LaunchDarkly::Impl::DataStore::DataKind]
        # @param key [String, Symbol]
        # @return [Object, nil]
        #
        def get(kind, key)
          items = @snapshot.get.contents[kind]
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
          @snapshot.get.contents[kind] || {}
        end

        #
        # Returns the current contents, keyed by data kind. The returned hash must not be modified.
        #
        # @return [Hash]
        #
        def contents
          @snapshot.get.contents
        end

        #
        # Returns true if the layer contains no entries.
        #
        # @return [Boolean]
        #
        def empty?
          @snapshot.get.contents.each_value.all?(&:empty?)
        end
      end
    end
  end
end
