require 'json'

module LaunchDarkly
  module Impl
    module DataSystem
      module ProtocolV2
        #
        # This module contains the protocol definitions and data types for the
        # LaunchDarkly data system version 2 (FDv2).
        #

        #
        # DeleteObject specifies the deletion of a particular object.
        #
        # This type is not stable, and not subject to any backwards
        # compatibility guarantees or semantic versioning. It is not suitable for production usage.
        #
        class DeleteObject
          # @return [Integer] The version
          attr_reader :version

          # @return [String] The object kind ({LaunchDarkly::Interfaces::DataSystem::ObjectKind})
          attr_reader :kind

          # @return [String] The key
          attr_reader :key

          #
          # @param version [Integer] The version
          # @param kind [String] The object kind ({LaunchDarkly::Interfaces::DataSystem::ObjectKind})
          # @param key [String] The key
          #
          def initialize(version:, kind:, key:)
            @version = version
            @kind = kind
            @key = key
          end

          #
          # Returns the event name.
          #
          # @return [Symbol]
          #
          def name
            LaunchDarkly::Interfaces::DataSystem::EventName::DELETE_OBJECT
          end

          #
          # Serializes the DeleteObject to a JSON-compatible hash.
          #
          # @return [Hash]
          #
          def to_h
            {
              version: @version,
              kind: @kind,
              key: @key,
            }
          end

          #
          # Deserializes a DeleteObject from a JSON-compatible hash.
          #
          # @param data [Hash] The hash representation
          # @return [DeleteObject]
          # @raise [ArgumentError] if required fields are missing
          #
          def self.from_h(data)
            version = data[:version]
            kind = data[:kind]
            key = data[:key]

            raise ArgumentError, "Missing required fields in DeleteObject" if version.nil? || kind.nil? || key.nil?

            new(version: version, kind: kind, key: key)
          end
        end

        #
        # PutObject specifies the addition of a particular object with upsert semantics.
        #
        # This type is not stable, and not subject to any backwards
        # compatibility guarantees or semantic versioning. It is not suitable for production usage.
        #
        class PutObject
          # @return [Integer] The version
          attr_reader :version

          # @return [String] The object kind ({LaunchDarkly::Interfaces::DataSystem::ObjectKind})
          attr_reader :kind

          # @return [String] The key
          attr_reader :key

          # @return [Hash] The object data
          attr_reader :object

          #
          # @param version [Integer] The version
          # @param kind [String] The object kind ({LaunchDarkly::Interfaces::DataSystem::ObjectKind})
          # @param key [String] The key
          # @param object [Hash] The object data
          #
          def initialize(version:, kind:, key:, object:)
            @version = version
            @kind = kind
            @key = key
            @object = object
          end

          #
          # Returns the event name.
          #
          # @return [Symbol]
          #
          def name
            LaunchDarkly::Interfaces::DataSystem::EventName::PUT_OBJECT
          end

          #
          # Serializes the PutObject to a JSON-compatible hash.
          #
          # @return [Hash]
          #
          def to_h
            {
              version: @version,
              kind: @kind,
              key: @key,
              object: @object,
            }
          end

          #
          # Deserializes a PutObject from a JSON-compatible hash.
          #
          # @param data [Hash] The hash representation
          # @return [PutObject]
          # @raise [ArgumentError] if required fields are missing
          #
          def self.from_h(data)
            version = data[:version]
            kind = data[:kind]
            key = data[:key]
            object_data = data[:object]

            raise ArgumentError, "Missing required fields in PutObject" if version.nil? || kind.nil? || key.nil? || object_data.nil?

            new(version: version, kind: kind, key: key, object: object_data)
          end
        end

        #
        # Goodbye represents a goodbye event.
        #
        # This type is not stable, and not subject to any backwards
        # compatibility guarantees or semantic versioning. It is not suitable for production usage.
        #
        class Goodbye
          # @return [String] The reason for goodbye
          attr_reader :reason

          # @return [Boolean] Whether the goodbye is silent
          attr_reader :silent

          # @return [Boolean] Whether this represents a catastrophic failure
          attr_reader :catastrophe

          #
          # @param reason [String] The reason for goodbye
          # @param silent [Boolean] Whether the goodbye is silent
          # @param catastrophe [Boolean] Whether this represents a catastrophic failure
          #
          def initialize(reason:, silent:, catastrophe:)
            @reason = reason
            @silent = silent
            @catastrophe = catastrophe
          end

          #
          # Serializes the Goodbye to a JSON-compatible hash.
          #
          # @return [Hash]
          #
          def to_h
            {
              reason: @reason,
              silent: @silent,
              catastrophe: @catastrophe,
            }
          end

          #
          # Deserializes a Goodbye event from a JSON-compatible hash.
          #
          # @param data [Hash] The hash representation
          # @return [Goodbye]
          # @raise [ArgumentError] if required fields are missing
          #
          def self.from_h(data)
            reason = data[:reason]
            silent = data[:silent]
            catastrophe = data[:catastrophe]

            raise ArgumentError, "Missing required fields in Goodbye" if reason.nil? || silent.nil? || catastrophe.nil?

            new(reason: reason, silent: silent, catastrophe: catastrophe)
          end
        end

        #
        # Error represents an error event.
        #
        # This type is not stable, and not subject to any backwards
        # compatibility guarantees or semantic versioning. It is not suitable for production usage.
        #
        class Error
          # @return [String] The payload ID
          attr_reader :payload_id

          # @return [String] The reason for the error
          attr_reader :reason

          #
          # @param payload_id [String] The payload ID
          # @param reason [String] The reason for the error
          #
          def initialize(payload_id:, reason:)
            @payload_id = payload_id
            @reason = reason
          end

          #
          # Serializes the Error to a JSON-compatible hash.
          #
          # @return [Hash]
          #
          def to_h
            {
              payloadId: @payload_id,
              reason: @reason,
            }
          end

          #
          # Deserializes an Error from a JSON-compatible hash.
          #
          # @param data [Hash] The hash representation
          # @return [Error]
          # @raise [ArgumentError] if required fields are missing
          #
          def self.from_h(data)
            payload_id = data[:payloadId]
            reason = data[:reason]

            raise ArgumentError, "Missing required fields in Error" if payload_id.nil? || reason.nil?

            new(payload_id: payload_id, reason: reason)
          end
        end
      end
    end
  end
end
