
module LaunchDarkly
  module Impl
    #
    # Implements a dependency graph ordering for data to be stored in a feature store. We must use this
    # on every data set that will be passed to the feature store's init() method.
    #
    class FeatureStoreDataSetSorter
      #
      # Returns a copy of the input hash that has the following guarantees: the iteration order of the outer
      # hash will be in ascending order by the VersionDataKind's :priority property (if any), and for each
      # data kind that has a :get_dependency_keys function, the inner hash will have an iteration order
      # where B is before A if A has a dependency on B.
      #
      # This implementation relies on the fact that hashes in Ruby have an iteration order that is the same
      # as the insertion order. Also, due to the way we deserialize JSON received from LaunchDarkly, the
      # keys in the inner hash will always be symbols.
      #
      def self.sort_all_collections(all_data)
        outer_hash = {}
        kinds = all_data.keys.sort_by { |k|
          k[:priority].nil? ? k[:namespace].length : k[:priority]  # arbitrary order if priority is unknown
        }
        kinds.each do |kind|
          items = all_data[kind]
          outer_hash[kind] = self.sort_collection(kind, items)
        end
        outer_hash
      end

      def self.sort_collection(kind, input)
        dependency_fn = kind[:get_dependency_keys]
        return input if dependency_fn.nil? || input.empty?
        remaining_items = input.clone
        items_out = {}
        until remaining_items.empty?
          # pick a random item that hasn't been updated yet
          key, item = remaining_items.first
          self.add_with_dependencies_first(item, dependency_fn, remaining_items, items_out)
        end
        items_out
      end

      def self.add_with_dependencies_first(item, dependency_fn, remaining_items, items_out)
        item_key = item[:key].to_sym
        remaining_items.delete(item_key)  # we won't need to visit this item again
        dependency_fn.call(item).each do |dep_key|
          dep_item = remaining_items[dep_key.to_sym]
          self.add_with_dependencies_first(dep_item, dependency_fn, remaining_items, items_out) unless dep_item.nil?
        end
        items_out[item_key] = item
      end
    end
  end
end
