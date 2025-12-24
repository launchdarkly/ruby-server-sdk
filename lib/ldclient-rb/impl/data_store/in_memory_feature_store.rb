# frozen_string_literal: true

require "concurrent"
require "concurrent/atomics"
require "ldclient-rb/impl/data_store"
require "ldclient-rb/interfaces/data_system"

module LaunchDarkly
  module Impl
    module DataStore
      #
      # InMemoryFeatureStoreV2 is a read-only in-memory store implementation for FDv2.
      #
      class InMemoryFeatureStoreV2
        include LaunchDarkly::Interfaces::DataSystem::ReadOnlyStore
        def initialize(logger)
          @logger = logger
          @lock = Concurrent::ReadWriteLock.new
          @initialized = Concurrent::AtomicBoolean.new(false)
          @items = {}
        end

        #
        # (see LaunchDarkly::Interfaces::DataSystem::ReadOnlyStore#get)
        #
        def get(kind, key)
          @lock.with_read_lock do
            items_of_kind = @items[kind]
            return nil if items_of_kind.nil?

            item = items_of_kind[key]
            return nil if item.nil?
            return nil if item[:deleted]

            item
          end
        end

        #
        # (see LaunchDarkly::Interfaces::DataSystem::ReadOnlyStore#all)
        #
        def all(kind)
          @lock.with_read_lock do
            items_of_kind = @items[kind]
            return {} if items_of_kind.nil?

            items_of_kind.select { |_k, item| !item[:deleted] }
          end
        end

        #
        # (see LaunchDarkly::Interfaces::DataSystem::ReadOnlyStore#initialized?)
        #
        def initialized?
          @initialized.value
        end

        #
        # Initializes the store with a full set of data, replacing any existing data.
        #
        # @param collections [Hash<LaunchDarkly::Impl::DataStore::DataKind, Hash<String, Hash>>] Hash of data kinds to collections of items
        # @return [Boolean] true if successful, false otherwise
        #
        def set_basis(collections)
          all_decoded = decode_collection(collections)
          return false if all_decoded.nil?

          @lock.with_write_lock do
            @items.clear
            @items.update(all_decoded)
            @initialized.make_true
          end

          true
        rescue => e
          LaunchDarkly::Impl.log.error { "[LDClient] Failed applying set_basis: #{e.message}" }
          false
        end

        #
        # Applies a delta update to the store.
        #
        # @param collections [Hash<LaunchDarkly::Impl::DataStore::DataKind, Hash<String, Hash>>] Hash of data kinds to collections with updates
        # @return [Boolean] true if successful, false otherwise
        #
        def apply_delta(collections)
          all_decoded = decode_collection(collections)
          return false if all_decoded.nil?

          @lock.with_write_lock do
            all_decoded.each do |kind, kind_data|
              items_of_kind = @items[kind] ||= {}
              kind_data.each do |key, item|
                items_of_kind[key] = item
              end
            end
          end

          true
        rescue => e
          @logger.error { "[LDClient] Failed applying apply_delta: #{e.message}" }
          false
        end

        #
        # Decodes a collection of items.
        #
        # @param collections [Hash<LaunchDarkly::Impl::DataStore::DataKind, Hash<String, Hash>>] Hash of data kinds to collections
        # @return [Hash<LaunchDarkly::Impl::DataStore::DataKind, Hash<Symbol, Hash>>, nil] Decoded collection with symbol keys, or nil on error
        #
        private def decode_collection(collections)
          all_decoded = {}

          collections.each do |kind, collection|
            items_decoded = {}
            collection.each do |key, item|
              items_decoded[key] = LaunchDarkly::Impl::Model.deserialize(kind, item, @logger)
            end
            all_decoded[kind] = items_decoded
          end

          all_decoded
        rescue => e
          LaunchDarkly::Impl.log.error { "[LDClient] Failed decoding collection: #{e.message}" }
          nil
        end
      end
    end
  end
end
