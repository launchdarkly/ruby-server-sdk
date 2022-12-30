module LaunchDarkly
  module Impl
    class ContextFilter
      #
      # @param all_attributes_private [Boolean]
      # @param private_attributes [Array<String>]
      #
      def initialize(all_attributes_private, private_attributes)
        @all_attributes_private = all_attributes_private

        @private_attributes = []
        private_attributes.each do |attribute|
          reference = LaunchDarkly::Reference.create(attribute)
          @private_attributes << reference if reference.error.nil?
        end
      end

      #
      # Return a hash representation of the provided context with attribute
      # redaction applied.
      #
      # @param context [LaunchDarkly::LDContext]
      # @return [Hash]
      #
      def filter(context)
        return filter_single_context(context, true) unless context.multi_kind?

        filtered = {kind: 'multi'}
        (0...context.individual_context_count).each do |i|
          c = context.individual_context(i)
          next if c.nil?

          filtered[c.kind] = filter_single_context(c, false)
        end

        filtered
      end

      #
      # Apply redaction rules for a single context.
      #
      # @param context [LaunchDarkly::LDContext]
      # @param include_kind [Boolean]
      # @return [Hash]
      #
      private def filter_single_context(context, include_kind)
        filtered = {key: context.key}

        filtered[:kind] = context.kind if include_kind
        filtered[:anonymous] = true if context.get_value(:anonymous)

        redacted = []
        private_attributes = @private_attributes.concat(context.private_attributes)

        name = context.get_value(:name)
        if !name.nil? && !check_whole_attribute_private(:name, private_attributes, redacted)
          filtered[:name] = name
        end

        context.get_custom_attribute_names.each do |attribute|
          unless check_whole_attribute_private(attribute, private_attributes, redacted)
            value = context.get_value(attribute)
            filtered[attribute] = redact_json_value(nil, attribute, value, private_attributes, redacted)
          end
        end

        filtered[:_meta] = {redactedAttributes: redacted} unless redacted.empty?

        filtered
      end

      #
      # Check if an entire attribute should be redacted.
      #
      # @param attribute [Symbol]
      # @param private_attributes [Array<Reference>]
      # @param redacted [Array<Symbol>]
      # @return [Boolean]
      #
      private def check_whole_attribute_private(attribute, private_attributes, redacted)
        if @all_attributes_private
          redacted << attribute
          return true
        end

        private_attributes.each do |private_attribute|
          if private_attribute.component(0) == attribute && private_attribute.depth == 1
            redacted << attribute
            return true
          end
        end

        false
      end

      #
      # Apply redaction rules to the provided value.
      #
      # @param parent_path [Array<String>, nil]
      # @param name [String]
      # @param value [any]
      # @param private_attributes [Array<Reference>]
      # @param redacted [Array<Symbol>]
      # @return [any]
      #
      private def redact_json_value(parent_path, name, value, private_attributes, redacted)
        return value unless value.is_a?(Hash)

        ret = {}
        current_path = parent_path.clone || []
        current_path << name

        value.each do |k, v|
          was_redacted = false
          private_attributes.each do |private_attribute|
            next unless private_attribute.depth == (current_path.count + 1)

            component = private_attribute.component(current_path.count)
            next unless component == k

            match = true
            (0...current_path.count).each do |i|
              unless private_attribute.component(i) == current_path[i]
                match = false
                break
              end
            end

            if match
              redacted << private_attribute.raw_path.to_sym
              was_redacted = true
              break
            end
          end

          unless was_redacted
            ret[k] = redact_json_value(current_path, k, v, private_attributes, redacted)
          end
        end

        ret
      end
    end
  end
end