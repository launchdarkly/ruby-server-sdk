# frozen_string_literal: true

require "ldclient-rb/impl/model/serialization"

require "json"
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

        # The document of YAML content that is only a null, such as an empty file, a comment, or
        # "---": a document with no entries.
        NONE = new(flags: {}.freeze, flag_values: {}.freeze, segments: {}.freeze).freeze

        #
        # Parses the content of a data file in the given format. {FileData.format_of} chooses the
        # format of a file from its name.
        #
        # Whether content with no entries is valid depends on the format, like the rest of the
        # content. Content that is empty or only white space is not a JSON document, so it fails to
        # parse. In YAML it is a document with no entries, {NONE}, and so is a YAML document that is
        # only a null, such as one with only a comment. A document that is not a mapping, or whose
        # "flags", "flagValues", or "segments" member is not a mapping, is an error, and so is
        # content that is not valid UTF-8, in either format.
        #
        # @param content [String] UTF-8 content
        # @param format [Symbol] `:json` or `:yaml`
        # @return [Document]
        # @raise [ArgumentError] if the content is not a valid document
        # @raise [JSON::ParserError, Psych::SyntaxError] if the content cannot be parsed
        #
        def self.parse(content, format:)
          FileData.check_encoding(content)
          case format
          when :json
            # A file that is being rewritten in place can be empty for a moment. Failing to parse
            # keeps its last good data until it is complete.
            raise ArgumentError, "the file has no content, which is not a JSON document" if FileData.blank?(content)

            raw = JSON.parse(content)
          when :yaml
            # The YAML parser rejects some white space, such as a tab, that is still no content.
            return NONE if FileData.blank?(content)

            raw = YAML.safe_load(content)
            return NONE if raw.nil?
          else
            raise ArgumentError, "unknown file format #{format.inspect}"
          end
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

      # The endings of the names of the files that are read as YAML, compared without regard to
      # case. Every other file is read as JSON.
      YAML_FILE_NAME_ENDINGS = [".yaml", ".yml"].freeze

      # The bytes that count as white space when deciding whether content is empty.
      WHITE_SPACE_BYTES = [0x20, 0x09, 0x0a, 0x0d, 0x0b, 0x0c].freeze
      private_constant :WHITE_SPACE_BYTES

      #
      # Returns the format of a data file, which its name decides: a name that ends in ".yaml" or
      # ".yml", in any case, is YAML, and any other name is JSON.
      #
      # @param path [String]
      # @return [Symbol] `:json` or `:yaml`
      #
      def self.format_of(path)
        path.downcase.end_with?(*YAML_FILE_NAME_ENDINGS) ? :yaml : :json
      end

      #
      # Raises an error if the content is not valid UTF-8.
      #
      # @param content [String]
      # @raise [ArgumentError] if the content is not valid UTF-8
      #
      def self.check_encoding(content)
        return if content.valid_encoding?

        if content.b.start_with?(*UTF16_AND_UTF32_BOMS)
          raise ArgumentError, "the file is encoded in UTF-16 or UTF-32; data files must be UTF-8"
        end
        raise ArgumentError, "the file is not valid UTF-8"
      end

      #
      # Returns true if the content is empty or only white space.
      #
      # @param content [String]
      # @return [Boolean]
      #
      def self.blank?(content)
        content.each_byte.all? { |byte| WHITE_SPACE_BYTES.include?(byte) }
      end

      # The byte order marks of UTF-8 and of the encodings that files must not use.
      UTF8_BOM = "\xEF\xBB\xBF".b.freeze
      UTF16_AND_UTF32_BOMS = ["\xFF\xFE".b, "\xFE\xFF".b, "\x00\x00\xFE\xFF".b].freeze
      private_constant :UTF8_BOM, :UTF16_AND_UTF32_BOMS

      #
      # Reads the raw content of one file, as UTF-8 and without a UTF-8 byte order mark, whatever
      # the process's default encoding. The bytes are not checked here: {Document.parse} rejects
      # content that is not valid UTF-8, so that such a file fails to load like any other content
      # that cannot be parsed.
      #
      # @param path [String]
      # @return [String]
      # @raise [ReadError] if the file cannot be read
      #
      def self.read_file(path)
        content = File.binread(path)
        content = content.byteslice(UTF8_BOM.bytesize..) if content.start_with?(UTF8_BOM)
        content.force_encoding(Encoding::UTF_8)
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
        Document.parse(content, format: format_of(path))
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
      # value for every context. The flag is on, has the value as its only variation, and
      # serves that variation as its fallthrough, so an evaluation reports the FALLTHROUGH
      # reason kind.
      #
      # @param key [String]
      # @param value [Object]
      # @return [Hash]
      #
      def self.make_flag_with_value(key, value)
        {
          key: key,
          on: true,
          version: 1,
          fallthrough: { variation: 0 },
          variations: [value],
        }
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
