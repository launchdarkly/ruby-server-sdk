require "ldclient-rb/reference"


# See serialization.rb for implementation notes on the data model classes.

module LaunchDarkly
  module Impl
    module Model
      class Clause
        def initialize(data, errors_out = nil)
          @data = data
          @context_kind = data[:contextKind]
          @op = data[:op].to_sym
          if @op == :segmentMatch
            @attribute = nil
          else
            @attribute = (@context_kind.nil? || @context_kind.empty?) ? Reference.create_literal(data[:attribute]) : Reference.create(data[:attribute])
            unless errors_out.nil? || @attribute.error.nil?
              errors_out << "clause has invalid attribute: #{@attribute.error}"
            end
          end
          @values = data[:values] || []
          @negate = !!data[:negate]
        end

        # @return [Hash]
        attr_reader :data
        # @return [String|nil]
        attr_reader :context_kind
        # @return [LaunchDarkly::Reference]
        attr_reader :attribute
        # @return [Symbol]
        attr_reader :op
        # @return [Array]
        attr_reader :values
        # @return [Boolean]
        attr_reader :negate

        def as_json
          @data
        end
      end
    end
  end
end
