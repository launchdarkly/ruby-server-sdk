module LaunchDarkly
  module Impl
    module Context
      #
      # @param kind
      # @return [Boolean]
      #
      def self.validate_kind(kind)
        return false unless kind.is_a?(String)
        kind.match?(/^[\w.-]+$/) && kind != "kind" && kind != "multi"
      end

      #
      # @param key
      # @return [Boolean]
      #
      def self.validate_key(key)
        return false unless key.is_a?(String)
        key != ""
      end
    end
  end
end
