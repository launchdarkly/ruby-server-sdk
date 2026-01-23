# frozen_string_literal: true

module LaunchDarkly
  module Interfaces
    module DataSystem
      #
      # EventName represents the name of an event that can be sent by the server for FDv2.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      module EventName
        # Specifies that an object should be added to the data set with upsert semantics.
        PUT_OBJECT = :"put-object"

        # Specifies that an object should be removed from the data set.
        DELETE_OBJECT = :"delete-object"

        # Specifies the server's intent.
        SERVER_INTENT = :"server-intent"

        # Specifies that all data required to bring the existing data set to a new version has been transferred.
        PAYLOAD_TRANSFERRED = :"payload-transferred"

        # Keeps the connection alive.
        HEARTBEAT = :"heart-beat"

        # Specifies that the server is about to close the connection.
        GOODBYE = :goodbye

        # Specifies that an error occurred while serving the connection.
        ERROR = :error
      end

      #
      # ObjectKind represents the kind of object.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      module ObjectKind
        # Represents a feature flag.
        FLAG = "flag"

        # Represents a segment.
        SEGMENT = "segment"
      end

      #
      # ChangeType specifies if an object is being upserted or deleted.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      module ChangeType
        # Represents an object being upserted.
        PUT = "put"

        # Represents an object being deleted.
        DELETE = "delete"
      end

      #
      # IntentCode represents the various intents that can be sent by the server.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      module IntentCode
        # The server intends to send a full data set.
        TRANSFER_FULL = "xfer-full"

        # The server intends to send only the necessary changes to bring an existing data set up-to-date.
        TRANSFER_CHANGES = "xfer-changes"

        # The server intends to send no data (payload is up to date).
        TRANSFER_NONE = "none"
      end

      #
      # DataStoreMode represents the mode of operation of a Data Store in FDV2 mode.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      module DataStoreMode
        # Indicates that the data store is read-only. Data will never be written back to the store by the SDK.
        READ_ONLY = :read_only

        # Indicates that the data store is read-write. Data from initializers/synchronizers may be written
        # to the store as necessary.
        READ_WRITE = :read_write
      end

      #
      # Selector represents a particular snapshot of data.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      class Selector
        # @return [String] The state
        attr_reader :state

        # @return [Integer] The version
        attr_reader :version

        #
        # @param state [String] The state
        # @param version [Integer] The version
        #
        def initialize(state: "", version: 0)
          @state = state
          @version = version
        end

        #
        # Returns an empty Selector.
        #
        # @return [Selector]
        #
        def self.no_selector
          Selector.new
        end

        #
        # Returns true if the Selector has a value.
        #
        # @return [Boolean]
        #
        def defined?
          self != Selector.no_selector
        end

        #
        # Returns the event name for payload transfer.
        #
        # @return [Symbol]
        #
        def name
          EventName::PAYLOAD_TRANSFERRED
        end

        #
        # Creates a new Selector from a state string and version.
        #
        # @param state [String] The state
        # @param version [Integer] The version
        # @return [Selector]
        #
        def self.new_selector(state, version)
          Selector.new(state: state, version: version)
        end

        #
        # Serializes the Selector to a Hash.
        #
        # @return [Hash]
        #
        def to_h
          {
            state: @state,
            version: @version,
          }
        end

        #
        # Deserializes a Selector from a Hash.
        #
        # @param data [Hash] The hash representation
        # @return [Selector]
        # @raise [ArgumentError] if required fields are missing
        #
        def self.from_h(data)
          state = data['state'] || data[:state]
          version = data['version'] || data[:version]

          raise ArgumentError, "Missing required fields in Selector" if state.nil? || version.nil?

          Selector.new(state: state, version: version)
        end

        def ==(other)
          other.is_a?(Selector) && @state == other.state && @version == other.version
        end

        def eql?(other)
          self == other
        end

        def hash
          [@state, @version].hash
        end
      end

      #
      # Change represents a change to a piece of data, such as an update or deletion.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      class Change
        # @return [String] The action ({ChangeType})
        attr_reader :action

        # @return [String] The kind ({ObjectKind})
        attr_reader :kind

        # @return [Symbol] The key
        attr_reader :key

        # @return [Integer] The version
        attr_reader :version

        # @return [Hash, nil] The object data (for PUT actions)
        attr_reader :object

        #
        # @param action [String] The action type ({ChangeType})
        # @param kind [String] The object kind ({ObjectKind})
        # @param key [Symbol] The key
        # @param version [Integer] The version
        # @param object [Hash, nil] The object data
        #
        def initialize(action:, kind:, key:, version:, object: nil)
          @action = action
          @kind = kind
          @key = key
          @version = version
          @object = object
        end
      end

      #
      # ChangeSet represents a list of changes to be applied.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      class ChangeSet
        # @return [String] The intent code ({IntentCode})
        attr_reader :intent_code

        # @return [Array<Change>] The changes
        attr_reader :changes

        # @return [Selector, nil] The selector
        attr_reader :selector

        #
        # @param intent_code [String] The intent code ({IntentCode})
        # @param changes [Array<Change>] The changes
        # @param selector [Selector, nil] The selector
        #
        def initialize(intent_code:, changes:, selector:)
          @intent_code = intent_code
          @changes = changes
          @selector = selector
        end
      end

      #
      # Basis represents the initial payload of data that a data source can provide.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      class Basis
        # @return [ChangeSet] The change set
        attr_reader :change_set

        # @return [Boolean] Whether to persist
        attr_reader :persist

        # @return [String, nil] The environment ID
        attr_reader :environment_id

        #
        # @param change_set [ChangeSet] The change set
        # @param persist [Boolean] Whether to persist
        # @param environment_id [String, nil] The environment ID
        #
        def initialize(change_set:, persist:, environment_id: nil)
          @change_set = change_set
          @persist = persist
          @environment_id = environment_id
        end
      end

      #
      # Payload represents a payload delivered in a streaming response.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      class Payload
        # @return [String] The payload ID
        attr_reader :id

        # @return [Integer] The target
        attr_reader :target

        # @return [String] The intent code ({IntentCode})
        attr_reader :code

        # @return [String] The reason
        attr_reader :reason

        #
        # @param id [String] The payload ID
        # @param target [Integer] The target
        # @param code [String] The intent code ({IntentCode})
        # @param reason [String] The reason
        #
        def initialize(id:, target:, code:, reason:)
          @id = id
          @target = target
          @code = code
          @reason = reason
        end

        #
        # Serializes the Payload to a Hash.
        #
        # @return [Hash]
        #
        def to_h
          {
            id: @id,
            target: @target,
            intentCode: @code,
            reason: @reason,
          }
        end

        #
        # Deserializes a Payload from a Hash.
        #
        # @param data [Hash] The hash representation
        # @return [Payload]
        # @raise [ArgumentError] if required fields are missing or invalid
        #
        def self.from_h(data)
          intent_code = data['intentCode'] || data[:intentCode]

          raise ArgumentError, "Invalid data for Payload: 'intentCode' key is missing or not a string" if intent_code.nil? || !intent_code.is_a?(String)

          Payload.new(
            id: data['id'] || data[:id] || "",
            target: data['target'] || data[:target] || 0,
            code: intent_code,
            reason: data['reason'] || data[:reason] || ""
          )
        end
      end

      #
      # ServerIntent represents the type of change associated with the payload.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      class ServerIntent
        # @return [Payload] The payload
        attr_reader :payload

        #
        # @param payload [Payload] The payload
        #
        def initialize(payload:)
          @payload = payload
        end

        #
        # Serializes the ServerIntent to a Hash.
        #
        # @return [Hash]
        #
        def to_h
          {
            payloads: [@payload.to_h],
          }
        end

        #
        # Deserializes a ServerIntent from a Hash.
        #
        # @param data [Hash] The hash representation
        # @return [ServerIntent]
        # @raise [ArgumentError] if required fields are missing or invalid
        #
        def self.from_h(data)
          payloads = data['payloads'] || data[:payloads]

          raise ArgumentError, "Invalid data for ServerIntent: 'payloads' key is missing or not an array" unless payloads.is_a?(Array)
          raise ArgumentError, "Invalid data for ServerIntent: expected exactly one payload" unless payloads.length == 1

          payload = payloads[0]
          raise ArgumentError, "Invalid payload in ServerIntent: expected a hash" unless payload.is_a?(Hash)

          ServerIntent.new(payload: Payload.from_h(payload))
        end
      end

      #
      # ChangeSetBuilder is a helper for constructing a ChangeSet.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      class ChangeSetBuilder
        # @return [String, nil] The current intent ({IntentCode})
        attr_accessor :intent

        # @return [Array<Change>] The changes
        attr_accessor :changes

        def initialize
          @intent = nil
          @changes = []
        end

        #
        # Represents an intent that the current data is up-to-date and doesn't require changes.
        #
        # @return [ChangeSet]
        #
        def self.no_changes
          ChangeSet.new(
            intent_code: IntentCode::TRANSFER_NONE,
            selector: Selector.no_selector,
            changes: []
          )
        end

        #
        # Returns an empty ChangeSet, useful for initializing without data.
        #
        # @param selector [Selector] The selector
        # @return [ChangeSet]
        #
        def self.empty(selector)
          ChangeSet.new(
            intent_code: IntentCode::TRANSFER_FULL,
            selector: selector,
            changes: []
          )
        end

        #
        # Begins a new change set with a given intent.
        #
        # @param intent [String] The intent code ({IntentCode})
        # @return [void]
        #
        def start(intent)
          @intent = intent
          @changes = []
        end

        #
        # Ensures that the current ChangeSetBuilder is prepared to handle changes.
        #
        # @return [void]
        # @raise [RuntimeError] if no server-intent has been set
        #
        def expect_changes
          raise "changeset: cannot expect changes without a server-intent" if @intent.nil?

          return unless @intent == IntentCode::TRANSFER_NONE

          @intent = IntentCode::TRANSFER_CHANGES
        end

        #
        # Clears any existing changes while preserving the current intent.
        #
        # @return [void]
        #
        def reset
          @changes = []
        end

        #
        # Identifies a changeset with a selector and returns the completed changeset.
        #
        # @param selector [Selector] The selector
        # @return [ChangeSet]
        # @raise [RuntimeError] if no server-intent has been set
        #
        def finish(selector)
          raise "changeset: cannot complete without a server-intent" if @intent.nil?

          changeset = ChangeSet.new(
            intent_code: @intent,
            selector: selector,
            changes: @changes
          )
          @changes = []

          # Once a full transfer has been processed, all future changes should be
          # assumed to be changes. Flag delivery can override this behavior by
          # sending a new server intent to any connected stream.
          @intent = IntentCode::TRANSFER_CHANGES if @intent == IntentCode::TRANSFER_FULL

          changeset
        end

        #
        # Adds a new object to the changeset.
        #
        # @param kind [String] The object kind ({ObjectKind})
        # @param key [Symbol] The key
        # @param version [Integer] The version
        # @param obj [Hash] The object data
        # @return [void]
        #
        def add_put(kind, key, version, obj)
          @changes << Change.new(
            action: ChangeType::PUT,
            kind: kind,
            key: key,
            version: version,
            object: obj
          )
        end

        #
        # Adds a deletion to the changeset.
        #
        # @param kind [String] The object kind ({ObjectKind})
        # @param key [Symbol] The key
        # @param version [Integer] The version
        # @return [void]
        #
        def add_delete(kind, key, version)
          @changes << Change.new(
            action: ChangeType::DELETE,
            kind: kind,
            key: key,
            version: version
          )
        end
      end

      #
      # Update represents the results of a synchronizer's ongoing sync method.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      class Update
        # @return [Symbol] The data source state ({LaunchDarkly::Interfaces::DataSource::Status})
        attr_reader :state

        # @return [ChangeSet, nil] The change set
        attr_reader :change_set

        # @return [LaunchDarkly::Interfaces::DataSource::ErrorInfo, nil] Error information
        attr_reader :error

        # @return [Boolean] Whether to revert to FDv1
        attr_reader :revert_to_fdv1

        # @return [String, nil] The environment ID
        attr_reader :environment_id

        #
        # @param state [Symbol] The data source state ({LaunchDarkly::Interfaces::DataSource::Status})
        # @param change_set [ChangeSet, nil] The change set
        # @param error [LaunchDarkly::Interfaces::DataSource::ErrorInfo, nil] Error information
        # @param revert_to_fdv1 [Boolean] Whether to revert to FDv1
        # @param environment_id [String, nil] The environment ID
        #
        def initialize(state:, change_set: nil, error: nil, revert_to_fdv1: false, environment_id: nil)
          @state = state
          @change_set = change_set
          @error = error
          @revert_to_fdv1 = revert_to_fdv1
          @environment_id = environment_id
        end
      end

      #
      # SelectorStore represents a component capable of providing Selectors for data retrieval.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      module SelectorStore
        #
        # Returns a Selector object that defines the criteria for data retrieval.
        #
        # @return [Selector]
        #
        def selector
          raise NotImplementedError, "#{self.class} must implement #selector"
        end
      end

      #
      # ReadOnlyStore represents a read-only store interface for retrieving data.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      module ReadOnlyStore
        #
        # Retrieves an item by kind and key.
        #
        # @param kind [LaunchDarkly::Impl::DataStore::DataKind] The data kind (e.g., LaunchDarkly::Impl::DataStore::FEATURES, LaunchDarkly::Impl::DataStore::SEGMENTS)
        # @param key [String] The item key
        # @return [Hash, nil] The item, or nil if not found or deleted
        #
        def get(kind, key)
          raise NotImplementedError, "#{self.class} must implement #get"
        end

        #
        # Retrieves all items of a given kind.
        #
        # @param kind [LaunchDarkly::Impl::DataStore::DataKind] The data kind (e.g., LaunchDarkly::Impl::DataStore::FEATURES, LaunchDarkly::Impl::DataStore::SEGMENTS)
        # @return [Hash] Hash of keys to items (excluding deleted items)
        #
        def all(kind)
          raise NotImplementedError, "#{self.class} must implement #all"
        end

        #
        # Returns whether the store has been initialized.
        #
        # @return [Boolean]
        #
        def initialized?
          raise NotImplementedError, "#{self.class} must implement #initialized?"
        end
      end

      #
      # Initializer represents a component capable of retrieving a single data result.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      module Initializer
        #
        # Returns the name of the initializer.
        #
        # @return [String]
        #
        def name
          raise NotImplementedError, "#{self.class} must implement #name"
        end

        #
        # Retrieves the initial data set for the data source.
        #
        # @param selector_store [SelectorStore] Provides the Selector
        # @return [LaunchDarkly::Result<Basis, String>]
        #
        def fetch(selector_store)
          raise NotImplementedError, "#{self.class} must implement #fetch"
        end
      end

      #
      # Synchronizer represents a component capable of synchronizing data from an external source.
      #
      # This type is not stable, and not subject to any backwards
      # compatibility guarantees or semantic versioning. It is not suitable for production usage.
      #
      # Do not use it.
      # You have been warned.
      #
      module Synchronizer
        #
        # Returns the name of the synchronizer.
        #
        # @return [String]
        #
        def name
          raise NotImplementedError, "#{self.class} must implement #name"
        end

        #
        # Begins the synchronization process, yielding Update objects.
        #
        # @param selector_store [SelectorStore] Provides the Selector
        # @yieldparam update [Update] The update
        # @return [void]
        #
        def sync(selector_store, &block)
          raise NotImplementedError, "#{self.class} must implement #sync"
        end

        #
        # Halts the synchronization process.
        #
        # @return [void]
        #
        def stop
          raise NotImplementedError, "#{self.class} must implement #stop"
        end
      end
    end
  end
end
