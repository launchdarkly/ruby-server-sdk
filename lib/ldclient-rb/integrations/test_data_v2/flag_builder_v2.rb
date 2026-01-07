require 'ldclient-rb/util'
require 'ldclient-rb/context'
require 'set'

module LaunchDarkly
  module Integrations
    class TestDataV2
      # Constants for boolean flag variation indices
      TRUE_VARIATION_INDEX = 0
      FALSE_VARIATION_INDEX = 1

      #
      # A builder for feature flag configurations to be used with {TestDataV2}.
      #
      # @see TestDataV2#flag
      # @see TestDataV2#update
      #
      class FlagBuilderV2
        # @api private
        attr_reader :_key

        # @api private
        def initialize(key)
          @_key = key
          @_on = true
          @_variations = []
          @_off_variation = nil
          @_fallthrough_variation = nil
          @_targets = {}
          @_rules = []
        end

        # Note that copy is private by convention, because we don't want developers to
        # consider it part of the public API, but it is still called from TestDataV2.
        #
        # Creates a deep copy of the flag builder. Subsequent updates to the
        # original `FlagBuilderV2` object will not update the copy and vise versa.
        #
        # @api private
        # @return [FlagBuilderV2] a copy of the flag builder object
        #
        def copy
          to = FlagBuilderV2.new(@_key)

          to.instance_variable_set(:@_on, @_on)
          to.instance_variable_set(:@_variations, @_variations.dup)
          to.instance_variable_set(:@_off_variation, @_off_variation)
          to.instance_variable_set(:@_fallthrough_variation, @_fallthrough_variation)
          to.instance_variable_set(:@_targets, deep_copy_targets)
          to.instance_variable_set(:@_rules, @_rules.dup)

          to
        end

        #
        # Sets targeting to be on or off for this flag.
        #
        # The effect of this depends on the rest of the flag configuration, just as it does on the
        # real LaunchDarkly dashboard. In the default configuration that you get from calling
        # {TestDataV2#flag} with a new flag key, the flag will return `false`
        # whenever targeting is off, and `true` when targeting is on.
        #
        # @param on [Boolean] true if targeting should be on
        # @return [FlagBuilderV2] the flag builder
        #
        def on(on)
          @_on = on
          self
        end

        #
        # Specifies the fallthrough variation. The fallthrough is the value
        # that is returned if targeting is on and the context was not matched by a more specific
        # target or rule.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param variation [Boolean, Integer] true or false or the desired fallthrough variation index:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilderV2] the flag builder
        #
        def fallthrough_variation(variation)
          if LaunchDarkly::Impl::Util.bool?(variation)
            boolean_flag.fallthrough_variation(variation_for_boolean(variation))
          else
            @_fallthrough_variation = variation
            self
          end
        end

        #
        # Specifies the off variation. This is the variation that is returned
        # whenever targeting is off.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param variation [Boolean, Integer] true or false or the desired off variation index:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilderV2] the flag builder
        #
        def off_variation(variation)
          if LaunchDarkly::Impl::Util.bool?(variation)
            boolean_flag.off_variation(variation_for_boolean(variation))
          else
            @_off_variation = variation
            self
          end
        end

        #
        # A shortcut for setting the flag to use the standard boolean configuration.
        #
        # This is the default for all new flags created with {TestDataV2#flag}.
        #
        # The flag will have two variations, `true` and `false` (in that order);
        # it will return `false` whenever targeting is off, and `true` when targeting is on
        # if no other settings specify otherwise.
        #
        # @return [FlagBuilderV2] the flag builder
        #
        def boolean_flag
          return self if boolean_flag?

          variations(true, false).fallthrough_variation(TRUE_VARIATION_INDEX).off_variation(FALSE_VARIATION_INDEX)
        end

        #
        # Changes the allowable variation values for the flag.
        #
        # The value may be of any valid JSON type. For instance, a boolean flag
        # normally has `true, false`; a string-valued flag might have
        # `'red', 'green'`; etc.
        #
        # @example A single variation
        #    td.flag('new-flag').variations(true)
        #
        # @example Multiple variations
        #   td.flag('new-flag').variations('red', 'green', 'blue')
        #
        # @param variations [Array<Object>] the desired variations
        # @return [FlagBuilderV2] the flag builder
        #
        def variations(*variations)
          @_variations = variations
          self
        end

        #
        # Sets the flag to always return the specified variation for all contexts.
        #
        # The variation is specified, targeting is switched on, and any existing targets or rules are removed.
        # The fallthrough variation is set to the specified value. The off variation is left unchanged.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param variation [Boolean, Integer] true or false or the desired variation index to return:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilderV2] the flag builder
        #
        def variation_for_all(variation)
          if LaunchDarkly::Impl::Util.bool?(variation)
            return boolean_flag.variation_for_all(variation_for_boolean(variation))
          end

          clear_rules.clear_targets.on(true).fallthrough_variation(variation)
        end

        #
        # Sets the flag to always return the specified variation value for all contexts.
        #
        # The value may be of any valid JSON type. This method changes the flag to have only
        # a single variation, which is this value, and to return the same variation
        # regardless of whether targeting is on or off. Any existing targets or rules
        # are removed.
        #
        # @param value [Object] the desired value to be returned for all contexts
        # @return [FlagBuilderV2] the flag builder
        #
        def value_for_all(value)
          variations(value).variation_for_all(0)
        end

        #
        # Sets the flag to return the specified variation for a specific user key when targeting
        # is on.
        #
        # This is a shortcut for calling {#variation_for_key} with
        # `LaunchDarkly::LDContext::KIND_DEFAULT` as the context kind.
        #
        # This has no effect when targeting is turned off for the flag.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param user_key [String] a user key
        # @param variation [Boolean, Integer] true or false or the desired variation index to return:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilderV2] the flag builder
        #
        def variation_for_user(user_key, variation)
          variation_for_key(LaunchDarkly::LDContext::KIND_DEFAULT, user_key, variation)
        end

        #
        # Sets the flag to return the specified variation for a specific context, identified
        # by context kind and key, when targeting is on.
        #
        # This has no effect when targeting is turned off for the flag.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param context_kind [String] the context kind
        # @param context_key [String] the context key
        # @param variation [Boolean, Integer] true or false or the desired variation index to return:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilderV2] the flag builder
        #
        def variation_for_key(context_kind, context_key, variation)
          if LaunchDarkly::Impl::Util.bool?(variation)
            return boolean_flag.variation_for_key(context_kind, context_key, variation_for_boolean(variation))
          end

          targets = @_targets[context_kind]
          if targets.nil?
            targets = {}
            @_targets[context_kind] = targets
          end

          @_variations.each_index do |idx|
            if idx == variation
              (targets[idx] ||= Set.new).add(context_key)
            elsif targets.key?(idx)
              targets[idx].delete(context_key)
            end
          end

          self
        end

        #
        # Starts defining a flag rule, using the "is one of" operator.
        #
        # This is a shortcut for calling {#if_match_context} with
        # `LaunchDarkly::LDContext::KIND_DEFAULT` as the context kind.
        #
        # @example create a rule that returns `true` if the name is "Patsy" or "Edina"
        #     td.flag("flag")
        #         .if_match('name', 'Patsy', 'Edina')
        #         .then_return(true)
        #
        # @param attribute [String] the user attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilderV2] the flag rule builder
        #
        def if_match(attribute, *values)
          if_match_context(LaunchDarkly::LDContext::KIND_DEFAULT, attribute, *values)
        end

        #
        # Starts defining a flag rule, using the "is one of" operator. This matching expression only
        # applies to contexts of a specific kind.
        #
        # @example create a rule that returns `true` if the name attribute for the
        #     "company" context is "Ella" or "Monsoon":
        #     td.flag("flag")
        #         .if_match_context('company', 'name', 'Ella', 'Monsoon')
        #         .then_return(True)
        #
        # @param context_kind [String] the context kind
        # @param attribute [String] the context attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilderV2] the flag rule builder
        #
        def if_match_context(context_kind, attribute, *values)
          flag_rule_builder = FlagRuleBuilderV2.new(self)
          flag_rule_builder.and_match_context(context_kind, attribute, *values)
        end

        #
        # Starts defining a flag rule, using the "is not one of" operator.
        #
        # This is a shortcut for calling {#if_not_match_context} with
        # `LaunchDarkly::LDContext::KIND_DEFAULT` as the context kind.
        #
        # @example create a rule that returns `true` if the name is neither "Saffron" nor "Bubble"
        #     td.flag("flag")
        #         .if_not_match('name', 'Saffron', 'Bubble')
        #         .then_return(true)
        #
        # @param attribute [String] the user attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilderV2] the flag rule builder
        #
        def if_not_match(attribute, *values)
          if_not_match_context(LaunchDarkly::LDContext::KIND_DEFAULT, attribute, *values)
        end

        #
        # Starts defining a flag rule, using the "is not one of" operator. This matching expression only
        # applies to contexts of a specific kind.
        #
        # @example create a rule that returns `true` if the name attribute for the
        #     "company" context is neither "Pendant" nor "Sterling Cooper":
        #     td.flag("flag")
        #         .if_not_match_context('company', 'name', 'Pendant', 'Sterling Cooper')
        #         .then_return(true)
        #
        # @param context_kind [String] the context kind
        # @param attribute [String] the context attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilderV2] the flag rule builder
        #
        def if_not_match_context(context_kind, attribute, *values)
          flag_rule_builder = FlagRuleBuilderV2.new(self)
          flag_rule_builder.and_not_match_context(context_kind, attribute, *values)
        end

        #
        # Removes any existing rules from the flag.
        # This undoes the effect of methods like {#if_match}.
        #
        # @return [FlagBuilderV2] the same flag builder
        #
        def clear_rules
          @_rules = []
          self
        end

        #
        # Removes any existing targets from the flag.
        # This undoes the effect of methods like {#variation_for_user}.
        #
        # @return [FlagBuilderV2] the same flag builder
        #
        def clear_targets
          @_targets = {}
          self
        end

        # Note that build is private by convention, because we don't want developers to
        # consider it part of the public API, but it is still called from TestDataV2.
        #
        # Creates a dictionary representation of the flag
        #
        # @api private
        # @param version [Integer] the version number of the flag
        # @return [Hash] the dictionary representation of the flag
        #
        def build(version)
          base_flag_object = {
            key: @_key,
            version: version,
            on: @_on,
            variations: @_variations,
            prerequisites: [],
            salt: '',
          }

          base_flag_object[:offVariation] = @_off_variation unless @_off_variation.nil?
          base_flag_object[:fallthrough] = { variation: @_fallthrough_variation } unless @_fallthrough_variation.nil?

          targets = []
          context_targets = []
          @_targets.each do |target_context_kind, target_variations|
            target_variations.each do |var_index, target_keys|
              if target_context_kind == LaunchDarkly::LDContext::KIND_DEFAULT
                targets << { variation: var_index, values: target_keys.to_a.sort } # sorting just for test determinacy
                context_targets << { contextKind: target_context_kind, variation: var_index, values: [] }
              else
                context_targets << { contextKind: target_context_kind, variation: var_index, values: target_keys.to_a.sort } # sorting just for test determinacy
              end
            end
          end
          base_flag_object[:targets] = targets unless targets.empty?
          base_flag_object[:contextTargets] = context_targets unless context_targets.empty?

          rules = []
          @_rules.each_with_index do |rule, idx|
            rules << rule.build(idx.to_s)
          end
          base_flag_object[:rules] = rules unless rules.empty?

          base_flag_object
        end

        private def variation_for_boolean(variation)
          variation ? TRUE_VARIATION_INDEX : FALSE_VARIATION_INDEX
        end

        private def boolean_flag?
          @_variations.length == 2 &&
            @_variations[TRUE_VARIATION_INDEX] == true &&
            @_variations[FALSE_VARIATION_INDEX] == false
        end

        private def add_rule(flag_rule_builder)
          @_rules << flag_rule_builder
        end

        private def deep_copy_targets
          to = {}
          @_targets.each do |k, v|
            to[k] = {}
            v.each do |var_idx, keys|
              to[k][var_idx] = keys.dup
            end
          end
          to
        end
      end

      #
      # A builder for feature flag rules to be used with {FlagBuilderV2}.
      #
      # In the LaunchDarkly model, a flag can have any number of rules, and a rule can have any number of
      # clauses. A clause is an individual test such as "name is 'X'". A rule matches a context if all of the
      # rule's clauses match the context.
      #
      # To start defining a rule, use one of the flag builder's matching methods such as
      # {FlagBuilderV2#if_match}. This defines the first clause for the rule.
      # Optionally, you may add more clauses with the rule builder's methods such as
      # {#and_match} or {#and_not_match}.
      # Finally, call {#then_return} to finish defining the rule.
      #
      class FlagRuleBuilderV2
        # @api private
        #
        # @param flag_builder [FlagBuilderV2] the flag builder instance
        #
        def initialize(flag_builder)
          @_flag_builder = flag_builder
          @_clauses = []
          @_variation = nil
        end

        #
        # Adds another clause, using the "is one of" operator.
        #
        # This is a shortcut for calling {#and_match_context} with
        # `LaunchDarkly::LDContext::KIND_DEFAULT` as the context kind.
        #
        # @example create a rule that returns `true` if the name is "Patsy" and the country is "gb"
        #     td.flag('flag')
        #         .if_match('name', 'Patsy')
        #         .and_match('country', 'gb')
        #         .then_return(true)
        #
        # @param attribute [String] the user attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilderV2] the flag rule builder
        #
        def and_match(attribute, *values)
          and_match_context(LaunchDarkly::LDContext::KIND_DEFAULT, attribute, *values)
        end

        #
        # Adds another clause, using the "is one of" operator. This matching expression only
        # applies to contexts of a specific kind.
        #
        # @example create a rule that returns `true` if the name attribute for the
        #     "company" context is "Ella", and the country attribute for the "company" context is "gb":
        #     td.flag('flag')
        #         .if_match_context('company', 'name', 'Ella')
        #         .and_match_context('company', 'country', 'gb')
        #         .then_return(true)
        #
        # @param context_kind [String] the context kind
        # @param attribute [String] the context attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilderV2] the flag rule builder
        #
        def and_match_context(context_kind, attribute, *values)
          @_clauses << {
            contextKind: context_kind,
            attribute: attribute,
            op: 'in',
            values: values.to_a,
            negate: false,
          }
          self
        end

        #
        # Adds another clause, using the "is not one of" operator.
        #
        # This is a shortcut for calling {#and_not_match_context} with
        # `LaunchDarkly::LDContext::KIND_DEFAULT` as the context kind.
        #
        # @example create a rule that returns `true` if the name is "Patsy" and the country is not "gb"
        #     td.flag('flag')
        #         .if_match('name', 'Patsy')
        #         .and_not_match('country', 'gb')
        #         .then_return(true)
        #
        # @param attribute [String] the user attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilderV2] the flag rule builder
        #
        def and_not_match(attribute, *values)
          and_not_match_context(LaunchDarkly::LDContext::KIND_DEFAULT, attribute, *values)
        end

        #
        # Adds another clause, using the "is not one of" operator. This matching expression only
        # applies to contexts of a specific kind.
        #
        # @example create a rule that returns `true` if the name attribute for the
        #     "company" context is "Ella", and the country attribute for the "company" context is not "gb":
        #     td.flag('flag')
        #         .if_match_context('company', 'name', 'Ella')
        #         .and_not_match_context('company', 'country', 'gb')
        #         .then_return(true)
        #
        # @param context_kind [String] the context kind
        # @param attribute [String] the context attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilderV2] the flag rule builder
        #
        def and_not_match_context(context_kind, attribute, *values)
          @_clauses << {
            contextKind: context_kind,
            attribute: attribute,
            op: 'in',
            values: values.to_a,
            negate: true,
          }
          self
        end

        #
        # Finishes defining the rule, specifying the result as either a boolean
        # or a variation index.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param variation [Boolean, Integer] true or false or the desired variation index:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilderV2] the flag builder with this rule added
        #
        def then_return(variation)
          if LaunchDarkly::Impl::Util.bool?(variation)
            @_flag_builder.boolean_flag
            return then_return(variation_for_boolean(variation))
          end

          @_variation = variation
          @_flag_builder.add_rule(self)
          @_flag_builder
        end

        # Note that build is private by convention, because we don't want developers to
        # consider it part of the public API, but it is still called from FlagBuilderV2.
        #
        # Creates a dictionary representation of the rule
        #
        # @api private
        # @param id [String] the rule id
        # @return [Hash] the dictionary representation of the rule
        #
        def build(id)
          {
            id: 'rule' + id,
            variation: @_variation,
            clauses: @_clauses,
          }
        end

        private def variation_for_boolean(variation)
          variation ? TRUE_VARIATION_INDEX : FALSE_VARIATION_INDEX
        end
      end
    end
  end
end

