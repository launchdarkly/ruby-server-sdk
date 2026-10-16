# frozen_string_literal: true

require "ldclient-rb/impl/data_store"
require "ldclient-rb/impl/dependency_tracker"
require "ldclient-rb/impl/model/serialization"
require "ldclient-rb/impl/overrides/layer"
require "ldclient-rb/interfaces/flag_tracker"
require "ldclient-rb/interfaces/overrides"

require "set"

module LaunchDarkly
  module Impl
    module Overrides
      #
      # Applies override layer replacements supplied by an override source, and notifies flag
      # change listeners of the flags affected by each replacement.
      #
      # @private
      #
      class Sink
        include LaunchDarkly::Interfaces::Overrides::OverrideSink

        KINDS = [DataStore::FEATURES, DataStore::SEGMENTS].freeze
        private_constant :KINDS

        #
        # @param layer [Layer] the layer to write to
        # @param base [#all] the store holding LaunchDarkly data, without the overlay. Merged-view
        #   snapshots for change computation are built from it plus the layer.
        # @param flag_change_broadcaster [LaunchDarkly::Impl::Broadcaster]
        # @param logger [Logger]
        #
        def initialize(layer, base, flag_change_broadcaster, logger)
          @layer = layer
          @base = base
          @flag_change_broadcaster = flag_change_broadcaster
          @logger = logger
          @lock = Mutex.new
        end

        #
        # Atomically replaces the entire override layer, then notifies listeners of every flag
        # whose merged-view evaluation may have changed. Calls are serialized, so overlapping
        # updates from a source cannot interleave.
        #
        # (see LaunchDarkly::Interfaces::Overrides::OverrideSink#set_overrides)
        #
        def set_overrides(flags, segments)
          flag_items = index_items(DataStore::FEATURES, flags)
          segment_items = index_items(DataStore::SEGMENTS, segments)

          @lock.synchronize do
            # Computing affected flags requires snapshots of the merged view before and after the
            # replacement. Skip all of that work when nothing is listening.
            unless @flag_change_broadcaster.has_listeners?
              @layer.set_all(flag_items, segment_items)
              return
            end

            previous, current = @layer.set_all(flag_items, segment_items)
            old_merged = merged_view(previous)
            new_merged = merged_view(current)

            affected = Sink.affected_flag_keys(previous, current, old_merged, new_merged)
            @logger.debug { "[LDClient] Override update affected #{affected.length} flag(s)" } unless affected.empty?
            affected.each do |key|
              @flag_change_broadcaster.broadcast(LaunchDarkly::Interfaces::FlagChange.new(key))
            end
          end
        end

        #
        # Returns the keys of all flags whose merged-view evaluation may have changed when the
        # override layer was replaced. The result includes the flags whose override entries were
        # added, removed, or changed. Dependency fan-out adds every flag that depends, directly or
        # transitively, on any added, removed, or changed entry of either kind.
        #
        # Dependency edges are computed over both the old and the new merged views, because a
        # replacement can rewire dependencies. For example, removing a flag override restores the
        # prerequisite edges of the LaunchDarkly definition.
        #
        # @param previous [Hash] layer contents before the replacement
        # @param current [Hash] layer contents after the replacement
        # @param old_merged [Hash] merged view before the replacement
        # @param new_merged [Hash] merged view after the replacement
        # @return [Array<String>]
        #
        def self.affected_flag_keys(previous, current, old_merged, new_merged)
          seeds = changed_entries(previous, current)
          return [] if seeds.empty?

          old_tracker = tracker_for(old_merged)
          new_tracker = tracker_for(new_merged)
          affected = Set.new
          seeds.each do |seed|
            old_tracker.add_affected_items(affected, seed)
            new_tracker.add_affected_items(affected, seed)
          end

          affected.select { |item| item[:kind] == DataStore::FEATURES }.map { |item| item[:key] }
        end

        #
        # Returns an item reference for each key whose override entry differs between the two
        # layer snapshots. An added or removed entry is always a change, even when its content
        # matches the underlying LaunchDarkly data. The override marker alone changes the served
        # entry. Entries present in both snapshots are compared by their data.
        #
        private_class_method def self.changed_entries(previous, current)
          seeds = []
          KINDS.each do |kind|
            old_items = previous[kind] || {}
            new_items = current[kind] || {}
            old_items.each do |key, old_item|
              new_item = new_items[key]
              seeds << { kind: kind, key: key.to_s } if new_item.nil? || old_item != new_item || old_item.version != new_item.version
            end
            new_items.each_key do |key|
              seeds << { kind: kind, key: key.to_s } unless old_items.key?(key)
            end
          end
          seeds
        end

        #
        # Builds a dependency tracker over a merged view. The tracker keys items by string, the
        # same form in which the data model names prerequisites and segments.
        #
        private_class_method def self.tracker_for(view)
          tracker = DependencyTracker.new
          KINDS.each do |kind|
            view[kind].each do |key, item|
              tracker.update_dependencies_from(kind, key.to_s, item)
            end
          end
          tracker
        end

        #
        # Converts the definitions passed to the sink into a hash keyed by symbol. A hash entry is
        # deserialized into the data model. A model object is used as is.
        #
        private def index_items(kind, items)
          result = {}
          (items || []).each do |item|
            model = Model.deserialize(kind, item, @logger)
            key = model.respond_to?(:key) ? model.key : nil
            raise ArgumentError, "an override #{kind.namespace} entry has no key" if key.nil? || key.to_s.empty?

            result[key.to_sym] = model
          end
          result
        end

        #
        # Captures the merged view of the base store and a layer snapshot: base data with override
        # entries overlaid. A base read failure for a kind yields just the overrides for that kind.
        # This degrades the dependency fan-out but never loses the directly changed keys.
        #
        private def merged_view(layer_contents)
          view = {}
          KINDS.each do |kind|
            items = {}
            begin
              @base.all(kind).each { |key, item| items[key.to_sym] = item }
            rescue => e
              @logger.warn { "[LDClient] Unable to read #{kind.namespace} for override change detection: #{e.message}" }
            end
            (layer_contents[kind] || {}).each { |key, item| items[key.to_sym] = item }
            view[kind] = items
          end
          view
        end
      end
    end
  end
end
