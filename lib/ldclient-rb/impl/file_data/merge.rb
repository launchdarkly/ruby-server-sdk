# frozen_string_literal: true

require "ldclient-rb/impl/data_store"
require "ldclient-rb/impl/file_data/document"
require "ldclient-rb/impl/model/serialization"

module LaunchDarkly
  module Impl
    module FileData
      #
      # Values for the duplicate keys handling option. They select what happens when the same
      # flag or segment key appears in more than one document.
      #
      module DuplicateKeysHandling
        # A duplicated key makes the merge fail.
        FAIL = :fail

        # Only the first occurrence of a duplicated key is kept, in the order the documents were given.
        IGNORE = :ignore

        ALL = [FAIL, IGNORE].freeze
      end

      #
      # Raised when documents cannot be combined, for example because a key is duplicated or an
      # entry is not an object.
      #
      class MergeError < StandardError
      end

      #
      # Counts the entries the merge kept from one document.
      #
      DocumentSummary = Struct.new(:flags, :segments)

      #
      # Describes one configured file after a reload. `present` is false when the file does not
      # exist and missing files are skipped.
      #
      FileSummary = Struct.new(:path, :present, :flags, :segments)

      #
      # The merged items from one or more documents.
      #
      class MergeResult
        # @return [Hash{Symbol => LaunchDarkly::Impl::Model::FeatureFlag}]
        attr_reader :flags

        # @return [Hash{Symbol => LaunchDarkly::Impl::Model::Segment}]
        attr_reader :segments

        # @return [Array<DocumentSummary>] one entry per input document, in order
        attr_reader :documents

        # @return [Array<FileSummary>] set by the Reloader, one entry per configured file, in order
        attr_accessor :files

        def initialize(flags, segments, documents)
          @flags = flags
          @segments = segments
          @documents = documents
          @files = []
        end

        # @return [Boolean]
        def empty?
          @flags.empty? && @segments.empty?
        end
      end

      #
      # Combines the items of the given documents into one set of flags and one set of segments.
      # Flag key to value entries expand into full flag definitions. Entries are deserialized into
      # the SDK's data model classes, which validate them. The documents are processed in order,
      # and the configured duplicate keys handling applies when the same key appears more than once.
      #
      # Items are keyed by the key under which they appear in the document. An entry that has no
      # "key" member receives that key. A missing "version" defaults to 1. When `version` is given,
      # every entry receives that version instead.
      #
      # @param documents [Array<Document>]
      # @param duplicate_keys_handling [Symbol] one of the {DuplicateKeysHandling} values
      # @param logger [Logger, nil] receives data model validation messages
      # @param version [Integer, nil] a version to stamp on every entry
      # @param off_value_flags [Boolean] if true, a flag key to value entry expands into a flag that is
      #   off and serves the value as its off variation. See {FileData.make_flag_with_value}.
      # @return [MergeResult]
      # @raise [MergeError] if the documents cannot be combined
      #
      def self.merge(documents, duplicate_keys_handling: DuplicateKeysHandling::FAIL, logger: nil, version: nil,
                     off_value_flags: false)
        flags = {}
        segments = {}
        summaries = []

        documents.each do |document|
          summary = DocumentSummary.new(0, 0)

          document.flags.each do |key, data|
            data = prepare_entry("flag", key, data, version)
            item = Model.deserialize(DataStore::FEATURES, data, logger)
            summary.flags += 1 if insert(flags, "flag", key, item, duplicate_keys_handling)
          end

          document.flag_values.each do |key, value|
            data = make_flag_with_value(key.to_s, value, version || 1, off: off_value_flags)
            item = Model.deserialize(DataStore::FEATURES, data, logger)
            summary.flags += 1 if insert(flags, "flag", key, item, duplicate_keys_handling)
          end

          document.segments.each do |key, data|
            data = prepare_entry("segment", key, data, version)
            item = Model.deserialize(DataStore::SEGMENTS, data, logger)
            summary.segments += 1 if insert(segments, "segment", key, item, duplicate_keys_handling)
          end

          summaries << summary
        end

        MergeResult.new(flags, segments, summaries)
      end

      #
      # Validates one full flag or segment entry and fills in its key and version.
      #
      private_class_method def self.prepare_entry(category, key, data, version)
        raise MergeError, "#{category} \"#{key}\" is not an object" unless data.is_a?(Hash)

        data = data.dup
        data[:key] = key.to_s if data[:key].nil?
        if version.nil?
          data[:version] = 1 if data[:version].nil?
        else
          data[:version] = version
        end
        data
      end

      #
      # Adds an item unless its key was already seen. Returns true when it added the item.
      #
      private_class_method def self.insert(items, category, key, item, duplicate_keys_handling)
        key = key.to_sym
        if items.key?(key)
          return false if duplicate_keys_handling == DuplicateKeysHandling::IGNORE

          raise MergeError, "#{category} key \"#{key}\" was used more than once"
        end

        items[key] = item
        true
      end
    end
  end
end
