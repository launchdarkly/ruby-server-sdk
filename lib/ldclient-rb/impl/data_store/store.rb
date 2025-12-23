# frozen_string_literal: true

require "concurrent"
require "set"
require "ldclient-rb/impl/data_store"
require "ldclient-rb/impl/data_store/in_memory_feature_store"
require "ldclient-rb/impl/dependency_tracker"
require "ldclient-rb/interfaces/data_system"

module LaunchDarkly
  module Impl
    module DataStore
      #
      # Store is a dual-mode persistent/in-memory store that serves requests for
      # data from the evaluation algorithm.
      #
      # At any given moment one of two stores is active: in-memory, or persistent.
      # Once the in-memory store has data (either from initializers or a
      # synchronizer), the persistent store is no longer read from. From that point
      # forward, calls to get data will serve from the memory store.
      #
      class Store
        include LaunchDarkly::Interfaces::DataSystem::SelectorStore

        #
        # Initialize a new Store.
        #
        # @param flag_change_broadcaster [LaunchDarkly::Impl::Broadcaster] Broadcaster for flag change events
        # @param change_set_broadcaster [LaunchDarkly::Impl::Broadcaster] Broadcaster for changeset events
        # @param logger [Logger] The logger instance
        #
        def initialize(flag_change_broadcaster, change_set_broadcaster, logger)
          @logger = logger
          @persistent_store = nil
          @persistent_store_status_provider = nil
          @persistent_store_writable = false

          # Source of truth for flag evaluations once initialized
          @memory_store = InMemoryFeatureStoreV2.new

          # Used to track dependencies between items in the store
          @dependency_tracker = LaunchDarkly::Impl::DependencyTracker.new

          # Broadcasters for events
          @flag_change_broadcaster = flag_change_broadcaster
          @change_set_broadcaster = change_set_broadcaster

          # True if the data in the memory store may be persisted to the persistent store
          @persist = false

          # Points to the active store. Swapped upon initialization.
          @active_store = @memory_store

          # Identifies the current data
          @selector = LaunchDarkly::Interfaces::DataSystem::Selector.no_selector

          # Thread synchronization
          @lock = Mutex.new
        end

        #
        # Configure the store with a persistent store for read-only or read-write access.
        #
        # @param persistent_store [LaunchDarkly::Interfaces::FeatureStore] The persistent store implementation
        # @param writable [Boolean] Whether the persistent store should be written to
        # @param status_provider [LaunchDarkly::Impl::DataStore::StatusProviderV2, nil] Optional status provider for the persistent store
        # @return [Store] self for method chaining
        #
        def with_persistence(persistent_store, writable, status_provider = nil)
          @lock.synchronize do
            @persistent_store = persistent_store
            @persistent_store_writable = writable
            @persistent_store_status_provider = status_provider

            # Initially use persistent store as active until memory store has data
            @active_store = persistent_store
          end

          self
        end

        # (see LaunchDarkly::Interfaces::DataSystem::SelectorStore#selector)
        def selector
          @lock.synchronize do
            @selector
          end
        end

        #
        # Close the store and any persistent store if configured.
        #
        # @return [Exception, nil] Exception if close failed, nil otherwise
        #
        def close
          @lock.synchronize do
            return nil if @persistent_store.nil?

            begin
              @persistent_store.stop if @persistent_store.respond_to?(:stop)
            rescue => e
              return e
            end
          end

          nil
        end

        #
        # Apply a changeset to the store.
        #
        # @param change_set [LaunchDarkly::Interfaces::DataSystem::ChangeSet] The changeset to apply
        # @param persist [Boolean] Whether the changes should be persisted to the persistent store
        # @return [void]
        #
        def apply(change_set, persist)
          collections = changes_to_store_data(change_set.changes)

          @lock.synchronize do
            begin
              case change_set.intent_code
              when LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL
                set_basis(collections, change_set.selector, persist)
              when LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_CHANGES
                apply_delta(collections, change_set.selector, persist)
              when LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_NONE
                # No-op, no changes to apply
                return
              end

              # Notify changeset listeners
              @change_set_broadcaster.broadcast(change_set)
            rescue => e
              @logger.error { "[LDClient] Couldn't apply changeset: #{e.message}" }
            end
          end
        end

        #
        # Commit persists the data in the memory store to the persistent store, if configured.
        #
        # @return [Exception, nil] Exception if commit failed, nil otherwise
        #
        def commit
          @lock.synchronize do
            return nil unless should_persist?

            begin
              # Get all data from memory store and write to persistent store
              all_data = {}
              [FEATURES, SEGMENTS].each do |kind|
                all_data[kind] = @memory_store.all(kind)
              end
              @persistent_store.init(all_data)
            rescue => e
              return e
            end
          end

          nil
        end

        #
        # Get the currently active store for reading data.
        #
        # @return [LaunchDarkly::Interfaces::FeatureStore] The active store (memory or persistent)
        #
        def get_active_store
          @lock.synchronize do
            @active_store
          end
        end

        #
        # Check if the active store is initialized.
        #
        # @return [Boolean]
        #
        def initialized?
          get_active_store.initialized?
        end

        #
        # Get the data store status provider for the persistent store, if configured.
        #
        # @return [LaunchDarkly::Impl::DataStore::StatusProviderV2, nil] The data store status provider for the persistent store, if configured
        #
        def get_data_store_status_provider
          @lock.synchronize do
            @persistent_store_status_provider
          end
        end

        #
        # Set the basis of the store. Any existing data is discarded.
        #
        # @param collections [Hash{Object => Hash{String => Hash}}] Hash of data kinds to collections of items
        # @param selector [LaunchDarkly::Interfaces::DataSystem::Selector, nil] The selector
        # @param persist [Boolean] Whether to persist the data
        # @return [void]
        #
        private def set_basis(collections, selector, persist)
          # Take snapshot for change detection if we have flag listeners
          old_data = nil
          if @flag_change_broadcaster.has_listeners?
            old_data = {}
            [FEATURES, SEGMENTS].each do |kind|
              old_data[kind] = @memory_store.all(kind)
            end
          end

          ok = @memory_store.set_basis(collections)
          return unless ok

          # Update dependency tracker
          reset_dependency_tracker(collections)

          # Update state
          @persist = persist
          @selector = selector || LaunchDarkly::Interfaces::DataSystem::Selector.no_selector

          # Switch to memory store as active
          @active_store = @memory_store

          # Persist to persistent store if configured and writable
          @persistent_store.init(collections) if should_persist?

          # Send change events if we had listeners
          if old_data
            affected_items = compute_changed_items_for_full_data_set(old_data, collections)
            send_change_events(affected_items)
          end
        end

        #
        # Apply a delta update to the store.
        #
        # @param collections [Hash{Object => Hash{String => Hash}}] Hash of data kinds to collections with updates
        # @param selector [LaunchDarkly::Interfaces::DataSystem::Selector, nil] The selector
        # @param persist [Boolean] Whether to persist the changes
        # @return [void]
        #
        private def apply_delta(collections, selector, persist)
          ok = @memory_store.apply_delta(collections)
          return unless ok

          has_listeners = @flag_change_broadcaster.has_listeners?
          affected_items = Set.new

          collections.each do |kind, collection|
            collection.each do |key, item|
              @dependency_tracker.update_dependencies_from(kind, key, item)
              if has_listeners
                @dependency_tracker.add_affected_items(affected_items, { kind: kind, key: key })
              end
            end
          end

          # Update state
          @persist = persist
          @selector = selector || LaunchDarkly::Interfaces::DataSystem::Selector.no_selector

          if should_persist?
            collections.each do |kind, kind_data|
              kind_data.each do |_key, item|
                @persistent_store.upsert(kind, item)
              end
            end
          end

          # Send change events
          send_change_events(affected_items) unless affected_items.empty?
        end

        #
        # Returns whether data should be persisted to the persistent store.
        #
        # @return [Boolean]
        #
        private def should_persist?
          @persist && !@persistent_store.nil? && @persistent_store_writable
        end

        #
        # Convert a list of Changes to the pre-existing format used by FeatureStore.
        #
        # @param changes [Array<LaunchDarkly::Interfaces::DataSystem::Change>] List of changes
        # @return [Hash{Object => Hash{String => Hash}}] Hash suitable for FeatureStore operations
        #
        private def changes_to_store_data(changes)
          all_data = {
            FEATURES => {},
            SEGMENTS => {},
          }

          changes.each do |change|
            kind = change.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG ? FEATURES : SEGMENTS
            if change.action == LaunchDarkly::Interfaces::DataSystem::ChangeType::PUT && !change.object.nil?
              all_data[kind][change.key] = change.object
            elsif change.action == LaunchDarkly::Interfaces::DataSystem::ChangeType::DELETE
              all_data[kind][change.key] = { key: change.key, deleted: true, version: change.version }
            end
          end

          all_data
        end

        #
        # Reset dependency tracker with new full data set.
        #
        # @param all_data [Hash{Object => Hash{String => Hash}}] Hash of data kinds to items
        # @return [void]
        #
        private def reset_dependency_tracker(all_data)
          @dependency_tracker.reset
          all_data.each do |kind, items|
            items.each do |key, item|
              @dependency_tracker.update_dependencies_from(kind, key, item)
            end
          end
        end

        #
        # Send flag change events for affected items.
        #
        # @param affected_items [Set<Hash>] Set of {kind:, key:} hashes
        # @return [void]
        #
        private def send_change_events(affected_items)
          affected_items.each do |item|
            if item[:kind] == FEATURES
              @flag_change_broadcaster.broadcast(item[:key])
            end
          end
        end

        #
        # Compute which items changed between old and new data sets.
        #
        # @param old_data [Hash{Object => Hash{String => Hash}}] Old data hash
        # @param new_data [Hash{Object => Hash{String => Hash}}] New data hash
        # @return [Set<Hash>] Set of {kind:, key:} hashes
        #
        private def compute_changed_items_for_full_data_set(old_data, new_data)
          affected_items = Set.new

          [FEATURES, SEGMENTS].each do |kind|
            old_items = old_data[kind] || {}
            new_items = new_data[kind] || {}

            # Get all keys from both old and new data
            all_keys = Set.new(old_items.keys) | Set.new(new_items.keys)

            all_keys.each do |key|
              old_item = old_items[key]
              new_item = new_items[key]

              # If either is missing or versions differ, it's a change
              if old_item.nil? || new_item.nil?
                @dependency_tracker.add_affected_items(affected_items, { kind: kind, key: key })
              elsif old_item[:version] != new_item[:version]
                @dependency_tracker.add_affected_items(affected_items, { kind: kind, key: key })
              end
            end
          end

          affected_items
        end
      end
    end
  end
end
