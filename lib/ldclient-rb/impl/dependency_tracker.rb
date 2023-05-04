module LaunchDarkly
  module Impl
    class DependencyTracker
      def initialize
        @from = {}
        @to = {}
      end

      #
      # Updates the dependency graph when an item has changed.
      #
      # @param from_kind [Object] the changed item's kind
      # @param from_key [String] the changed item's key
      # @param from_item [Object] the changed item
      #
      def update_dependencies_from(from_kind, from_key, from_item)
        from_what = { kind: from_kind, key: from_key }
        updated_dependencies = DependencyTracker.compute_dependencies_from(from_kind, from_item)

        old_dependency_set = @from[from_what]
        unless old_dependency_set.nil?
          old_dependency_set.each do |kind_and_key|
            deps_to_this_old_dep = @to[kind_and_key]
            deps_to_this_old_dep&.delete(from_what)
          end
        end

        @from[from_what] = updated_dependencies
        updated_dependencies.each do |kind_and_key|
          deps_to_this_new_dep = @to[kind_and_key]
          if deps_to_this_new_dep.nil?
            deps_to_this_new_dep = Set.new
            @to[kind_and_key] = deps_to_this_new_dep
          end
          deps_to_this_new_dep.add(from_what)
        end
      end

      def self.segment_keys_from_clauses(clauses)
        clauses.flat_map do |clause|
          if clause.op == :segmentMatch
            clause.values.map { |value| {kind: LaunchDarkly::SEGMENTS, key: value }}
          else
            []
          end
        end
      end

      #
      # @param from_kind [String]
      # @param from_item [LaunchDarkly::Impl::Model::FeatureFlag, LaunchDarkly::Impl::Model::Segment]
      # @return [Set]
      #
      def self.compute_dependencies_from(from_kind, from_item)
        return Set.new if from_item.nil?

        if from_kind == LaunchDarkly::FEATURES
          prereq_keys = from_item.prerequisites.map { |prereq| {kind: from_kind, key: prereq.key} }
          segment_keys = from_item.rules.flat_map { |rule| DependencyTracker.segment_keys_from_clauses(rule.clauses) }

          results = Set.new(prereq_keys)
          results.merge(segment_keys)
        elsif from_kind == LaunchDarkly::SEGMENTS
          kind_and_keys  = from_item.rules.flat_map do |rule|
            DependencyTracker.segment_keys_from_clauses(rule.clauses)
          end
          Set.new(kind_and_keys)
        else
          Set.new
        end
      end

      #
      # Clear any tracked dependencies and reset the tracking state to a clean slate.
      #
      def reset
        @from.clear
        @to.clear
      end

      #
      # Populates the given set with the union of the initial item and all items that directly or indirectly
      # depend on it (based on the current state of the dependency graph).
      #
      # @param items_out [Set]
      # @param initial_modified_item [Object]
      #
      def add_affected_items(items_out, initial_modified_item)
        return if items_out.include? initial_modified_item

        items_out.add(initial_modified_item)
        affected_items = @to[initial_modified_item]

        return if affected_items.nil?

        affected_items.each do |affected_item|
          add_affected_items(items_out, affected_item)
        end
      end
    end
  end
end
