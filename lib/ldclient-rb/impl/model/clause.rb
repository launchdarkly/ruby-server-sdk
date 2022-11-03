
module LaunchDarkly
  module Impl
    module Model
      class Clause
        def initialize(data)
          @data = data
          @context_kind = data[:contextKind]
          @attribute = data[:attribute]
          @op = data[:op].to_sym
          @values = data[:values] || []
          @negate = !!data[:negate]
        end

        # @return [Hash]
        attr_reader :data
        # @return [String|nil]
        attr_reader :context_kind
        # @return [String]
        attr_reader :attribute
        # @return [Symbol]
        attr_reader :op
        # @return [Array]
        attr_reader :values
        # @return [Boolean]
        attr_reader :negate

        def [](key)
          @data[key]
        end

        def as_json
          @data
        end
      end
    end
  end
end
