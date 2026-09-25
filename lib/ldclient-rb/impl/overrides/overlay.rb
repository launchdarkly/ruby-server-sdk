# frozen_string_literal: true

require "ldclient-rb/impl/overrides/layer"
require "ldclient-rb/interfaces/data_system"

module LaunchDarkly
  module Impl
    module Overrides
      #
      # Merges an override {Layer} over a base store. A read for a key returns the override entry
      # when one exists, and the base entry otherwise. The overlay sits at the store read boundary.
      # That placement makes targeting rules, prerequisites, and segment matches behave identically
      # for overridden and ordinary data. They are the same reads through the same boundary.
      #
      # @private
      #
      class Overlay
        include LaunchDarkly::Interfaces::DataSystem::ReadOnlyStore

        #
        # @param base [#get, #all, #initialized?] the store that holds LaunchDarkly data
        # @param layer [Layer]
        #
        def initialize(base, layer)
          @base = base
          @layer = layer
        end

        #
        # Returns the override entry for the key if one exists, and otherwise delegates to the base
        # store. This works even when the base store is uninitialized, because an uninitialized
        # base reports not-found rather than failing.
        #
        # (see LaunchDarkly::Interfaces::DataSystem::ReadOnlyStore#get)
        #
        def get(kind, key)
          item = @layer.get(kind, key)
          return item unless item.nil?

          @base.get(kind, key)
        end

        #
        # Returns the union of the base store's items and the layer's items. The override entry
        # wins for any key present in both. This includes keys the base holds only as deleted
        # items.
        #
        # When the base store fails and the layer holds entries, the result is the layer's entries
        # alone, with no error. A per-key read serves those entries whatever the state of the base,
        # so an all-flags read does the same. When the layer is empty, the base error is raised.
        #
        # (see LaunchDarkly::Interfaces::DataSystem::ReadOnlyStore#all)
        #
        def all(kind)
          overrides = @layer.all(kind)
          begin
            base_items = @base.all(kind)
          rescue
            raise if overrides.empty?

            base_items = {}
          end
          return base_items if overrides.empty?

          base_items.merge(overrides)
        end

        #
        # Delegates to the base store: the override layer never affects initialization status or
        # data availability.
        #
        # (see LaunchDarkly::Interfaces::DataSystem::ReadOnlyStore#initialized?)
        #
        def initialized?
          @base.initialized?
        end
      end
    end
  end
end
