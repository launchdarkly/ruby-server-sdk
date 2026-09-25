# frozen_string_literal: true

require "ldclient-rb/impl/model/serialization"

require "yaml"

module LaunchDarkly
  module Impl
    #
    # Shared file reading, parsing, and merging code for the components that load flag and
    # segment data from local files.
    #
    # @private
    #
    module FileData
      #
      # Raised when a file cannot be read or parsed. It carries the path so that callers can
      # tell a per-file failure from a failure to merge the files' contents.
      #
      class ReadError < StandardError
        # @return [String]
        attr_reader :path

        # @return [Boolean] true when the file does not exist
        attr_reader :missing

        #
        # @param path [String]
        # @param message [String]
        # @param missing [Boolean]
        #
        def initialize(path, message, missing: false)
          super("#{message} [#{path}]")
          @path = path
          @missing = missing
        end
      end

      #
      # The parsed form of one data file. A document may contain full flag definitions, flag key
      # to value entries, and segment definitions. Every hash has symbol keys.
      #
      class Document
        # @return [Hash{Symbol => Hash}]
        attr_reader :flags

        # @return [Hash{Symbol => Object}]
        attr_reader :flag_values

        # @return [Hash{Symbol => Hash}]
        attr_reader :segments

        #
        # @param flags [Hash{Symbol => Hash}]
        # @param flag_values [Hash{Symbol => Object}]
        # @param segments [Hash{Symbol => Hash}]
        #
        def initialize(flags: {}, flag_values: {}, segments: {})
          @flags = flags
          @flag_values = flag_values
          @segments = segments
        end

        #
        # Parses the content of a data file. The content may be JSON or YAML. JSON is a subset of
        # YAML, and the Ruby YAML parser handles it, so one parser serves both formats.
        #
        # An empty document is a document with no entries. A document that is not a mapping, or
        # whose "flags", "flagValues", or "segments" member is not a mapping, is an error.
        #
        # @param content [String]
        # @return [Document]
        # @raise [ArgumentError] if the content is not a valid document
        # @raise [Psych::SyntaxError] if the content cannot be parsed
        #
        def self.parse(content)
          raw = YAML.safe_load(content)
          raw = {} if raw.nil?
          raise ArgumentError, "file content must be an object" unless raw.is_a?(Hash)

          data = FileData.symbolize_keys(raw)
          Document.new(
            flags: section(data, :flags),
            flag_values: section(data, :flagValues),
            segments: section(data, :segments)
          )
        end

        #
        # Reads and parses one data file.
        #
        # @param path [String]
        # @return [Document]
        # @raise [ReadError] if the file cannot be read or parsed
        #
        def self.read(path)
          content = FileData.read_file(path)
          FileData.parse_file(path, content)
        end

        private_class_method def self.section(data, name)
          value = data[name]
          return {} if value.nil?
          raise ArgumentError, "\"#{name}\" must be an object" unless value.is_a?(Hash)

          value
        end
      end

      #
      # Reads the raw content of one file.
      #
      # @param path [String]
      # @return [String]
      # @raise [ReadError] if the file cannot be read
      #
      def self.read_file(path)
        File.read(path)
      rescue Errno::ENOENT => e
        raise ReadError.new(path, "unable to read file: #{e.message}", missing: true)
      rescue SystemCallError, IOError => e
        raise ReadError.new(path, "unable to read file: #{e.message}")
      end

      #
      # Parses raw content that was read from the given path.
      #
      # @param path [String]
      # @param content [String]
      # @return [Document]
      # @raise [ReadError] if the content cannot be parsed
      #
      def self.parse_file(path, content)
        Document.parse(content)
      rescue StandardError => e
        raise ReadError.new(path, "error parsing file: #{e.message}")
      end

      #
      # Recursively converts hash keys to symbols. The SDK expects all data model objects to
      # have symbol keys.
      #
      # @param value [Object]
      # @return [Object]
      #
      def self.symbolize_keys(value)
        case value
        when Hash
          value.to_h { |k, v| [k.to_s.to_sym, symbolize_keys(v)] }
        when Array
          value.map { |v| symbolize_keys(v) }
        else
          value
        end
      end

      #
      # Expands a flag key to value entry into a full flag definition that returns the given
      # value for every context.
      #
      # By default the flag is on and serves the value through its fallthrough, which is how the
      # file data sources have always expanded these entries. With `off: true` the flag is off and
      # serves the value as its off variation, so an evaluation reports the OFF reason kind. The
      # override source uses that form.
      #
      # @param key [String]
      # @param value [Object]
      # @param version [Integer]
      # @param off [Boolean]
      # @return [Hash]
      #
      def self.make_flag_with_value(key, value, version = 1, off: false)
        if off
          {
            key: key,
            on: false,
            version: version,
            offVariation: 0,
            variations: [value],
          }
        else
          {
            key: key,
            on: true,
            version: version,
            fallthrough: { variation: 0 },
            variations: [value],
          }
        end
      end

      #
      # Converts each path to an absolute path.
      #
      # @param paths [Array<String>, String]
      # @return [Array<String>]
      #
      def self.absolute_paths(paths)
        Array(paths).map { |p| File.absolute_path(p.to_s) }
      end
    end
  end
end
