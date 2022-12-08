
# See serialization.rb for implementation notes on the data model classes.

module LaunchDarkly
  module Impl
    module Model
      class Clause
        def initialize(data, logger)
          @data = data
          @context_kind = data[:contextKind]
          @attribute = (@context_kind.nil? || @context_kind.empty?) ? Reference.create_literal(data[:attribute]) : Reference.create(data[:attribute])
          unless logger.nil? || @attribute.error.nil?
            logger.error("[LDClient] Data inconsistency in feature flag: #{@attribute.error}")
          end
          @op = data[:op].to_sym
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
