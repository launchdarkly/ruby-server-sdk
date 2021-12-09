require 'ldclient-rb/util'

module LaunchDarkly
  module Integrations
    class TestData
      #
      # A builder for feature flag configurations to be used with {TestData}.
      #
      # @see TestData#flag
      # @see TestData#update
      #
      class FlagBuilder
        attr_reader :key

        # @private
        def initialize(key)
          @key = key
          @on = true
          @variations = []
        end

        # @private
        def initialize_copy(other)
          super(other)
          @variations = @variations.clone
          @rules = @rules.nil? ? nil : deep_copy_array(@rules)
          @targets = @targets.nil? ? nil : deep_copy_hash(@targets)
        end

        #
        # Sets targeting to be on or off for this flag.
        #
        # The effect of this depends on the rest of the flag configuration, just as it does on the
        # real LaunchDarkly dashboard. In the default configuration that you get from calling
        # {TestData#flag} with a new flag key, the flag will return `false`
        # whenever targeting is off, and `true` when targeting is on.
        #
        # @param on [Boolean] true if targeting should be on
        # @return [FlagBuilder] the builder
        #
        def on(on)
          @on = on
          self
        end

        #
        # Specifies the fallthrough variation. The fallthrough is the value
        # that is returned if targeting is on and the user was not matched by a more specific
        # target or rule.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param variation [Boolean, Integer] true or false or the desired fallthrough variation index:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilder] the builder
        #
        def fallthrough_variation(variation)
          if LaunchDarkly::Impl::Util.is_bool variation then
            boolean_flag.fallthrough_variation(variation_for_boolean(variation))
          else
            @fallthrough_variation = variation
            self
          end
        end

        #
        # Specifies the off variation for a flag. This is the variation that is returned
        # whenever targeting is off.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param variation [Boolean, Integer] true or false or the desired off variation index:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilder] the builder
        #
        def off_variation(variation)
          if LaunchDarkly::Impl::Util.is_bool variation then
            boolean_flag.off_variation(variation_for_boolean(variation))
          else
            @off_variation = variation
            self
          end
        end

        #
        # Changes the allowable variation values for the flag.
        #
        # The value may be of any valid JSON type. For instance, a boolean flag
        # normally has `true, false`; a string-valued flag might have
        # `'red', 'green'`; etc.
        #
        # @example A single variation
        #    td.flag('new-flag')
        #      .variations(true)
        #
        # @example Multiple variations
        #   td.flag('new-flag')
        #     .variations('red', 'green', 'blue')
        #
        # @param variations [Array<Object>] the the desired variations
        # @return [FlagBuilder] the builder
        #
        def variations(*variations)
          @variations = variations
          self
        end

        #
        # Sets the flag to always return the specified variation for all users.
        #
        # The variation is specified, Targeting is switched on, and any existing targets or rules are removed.
        # The fallthrough variation is set to the specified value. The off variation is left unchanged.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param variation [Boolean, Integer] true or false or the desired variation index to return:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilder] the builder
        #
        def variation_for_all_users(variation)
          if LaunchDarkly::Impl::Util.is_bool variation then
            boolean_flag.variation_for_all_users(variation_for_boolean(variation))
          else
            on(true).clear_rules.clear_user_targets.fallthrough_variation(variation)
          end
        end

        #
        # Sets the flag to always return the specified variation value for all users.
        #
        # The value may be of any valid JSON type. This method changes the
        # flag to have only a single variation, which is this value, and to return the same
        # variation regardless of whether targeting is on or off. Any existing targets or rules
        # are removed.
        #
        # @param value [Object] the desired value to be returned for all users
        # @return [FlagBuilder] the builder
        #
        def value_for_all_users(value)
          variations(value).variation_for_all_users(0)
        end

        #
        # Sets the flag to return the specified variation for a specific user key when targeting
        # is on.
        #
        # This has no effect when targeting is turned off for the flag.
        #
        # If the flag was previously configured with other variations and the variation specified is a boolean,
        # this also changes it to a boolean flag.
        #
        # @param user_key [String] a user key
        # @param variation [Boolean, Integer] true or false or the desired variation index to return:
        #                  0 for the first, 1 for the second, etc.
        # @return [FlagBuilder] the builder
        #
        def variation_for_user(user_key, variation)
          if LaunchDarkly::Impl::Util.is_bool variation then
            boolean_flag.variation_for_user(user_key, variation_for_boolean(variation))
          else
            if @targets.nil? then
              @targets = Hash.new
            end
            @variations.count.times do | i |
              if i == variation then
                if @targets[i].nil? then
                  @targets[i] = [user_key]
                else
                  @targets[i].push(user_key)
                end
              elsif not @targets[i].nil? then
                @targets[i].delete(user_key)
              end
            end
            self
          end
        end

        #
        # Starts defining a flag rule, using the "is one of" operator.
        #
        # @example create a rule that returns `true` if the name is "Patsy" or "Edina"
        #     testData.flag("flag")
        #         .if_match(:name, 'Patsy', 'Edina')
        #         .then_return(true);
        #
        # @param attribute [Symbol] the user attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilder] a flag rule builder
        #
        # @see FlagRuleBuilder#then_return
        # @see FlagRuleBuilder#and_match
        # @see FlagRuleBuilder#and_not_match
        #
        def if_match(attribute, *values)
          FlagRuleBuilder.new(self).and_match(attribute, *values)
        end

        #
        # Starts defining a flag rule, using the "is not one of" operator.
        #
        # @example create a rule that returns `true` if the name is neither "Saffron" nor "Bubble"
        #     testData.flag("flag")
        #         .if_not_match(:name, 'Saffron', 'Bubble')
        #         .then_return(true)
        #
        # @param attribute [Symbol] the user attribute to match against
        # @param values [Array<Object>] values to compare to
        # @return [FlagRuleBuilder] a flag rule builder
        #
        # @see FlagRuleBuilder#then_return
        # @see FlagRuleBuilder#and_match
        # @see FlagRuleBuilder#and_not_match
        #
        def if_not_match(attribute, *values)
          FlagRuleBuilder.new(self).and_not_match(attribute, *values)
        end

        #
        # Removes any existing user targets from the flag.
        # This undoes the effect of methods like {#variation_for_user}
        #
        # @return [FlagBuilder] the same builder
        #
        def clear_user_targets
          @targets = nil
          self
        end

        #
        # Removes any existing rules from the flag.
        # This undoes the effect of methods like {#if_match}
        #
        # @return [FlagBuilder] the same builder
        #
        def clear_rules
          @rules = nil
          self
        end

        # @private
        def add_rule(rule)
          if @rules.nil? then
            @rules = Array.new
          end
          @rules.push(rule)
          self
        end

        #
        # A shortcut for setting the flag to use the standard boolean configuration.
        #
        # This is the default for all new flags created with {TestData#flag}.
        # The flag will have two variations, `true` and `false` (in that order);
        # it will return `false` whenever targeting is off, and `true` when targeting is on
        # if no other settings specify otherwise.
        #
        # @return [FlagBuilder] the builder
        #
        def boolean_flag
          if is_boolean_flag then
            self
          else
            variations(true, false)
              .fallthrough_variation(TRUE_VARIATION_INDEX)
              .off_variation(FALSE_VARIATION_INDEX)
          end
        end

        # @private
        def build(version)
          res = { key: @key,
                  version: version,
                  on: @on,
                  variations: @variations,
                }

          unless @off_variation.nil? then
            res[:offVariation] = @off_variation
          end

          unless @fallthrough_variation.nil? then
            res[:fallthrough] = { variation: @fallthrough_variation }
          end

          unless @targets.nil? then
            res[:targets] = @targets.collect do | variation, values |
              { variation: variation, values: values }
            end
          end

          unless @rules.nil? then
            res[:rules] = @rules.each_with_index.collect { | rule, i | rule.build(i) }
          end

          res
        end

        #
        # A builder for feature flag rules to be used with {FlagBuilder}.
        #
        # In the LaunchDarkly model, a flag can have any number of rules, and a rule can have any number of
        # clauses. A clause is an individual test such as "name is 'X'". A rule matches a user if all of the
        # rule's clauses match the user.
        #
        # To start defining a rule, use one of the flag builder's matching methods such as
        # {FlagBuilder#if_match}. This defines the first clause for the rule.
        # Optionally, you may add more clauses with the rule builder's methods such as
        # {#and_match} or {#and_not_match}.
        # Finally, call {#then_return} to finish defining the rule.
        #
        class FlagRuleBuilder
          # @private
          FlagRuleClause = Struct.new(:attribute, :op, :values, :negate, keyword_init: true)

          # @private
          def initialize(flag_builder)
            @flag_builder = flag_builder
            @clauses = Array.new
          end

          # @private
          def intialize_copy(other)
            super(other)
            @clauses = @clauses.clone
          end

          #
          # Adds another clause, using the "is one of" operator.
          #
          # @example create a rule that returns `true` if the name is "Patsy" and the country is "gb"
          #     testData.flag("flag")
          #         .if_match(:name, 'Patsy')
          #         .and_match(:country, 'gb')
          #         .then_return(true)
          #
          # @param attribute [Symbol] the user attribute to match against
          # @param values [Array<Object>] values to compare to
          # @return [FlagRuleBuilder] the rule builder
          #
          def and_match(attribute, *values)
            @clauses.push(FlagRuleClause.new(
              attribute: attribute,
              op: 'in',
              values: values,
              negate: false
            ))
            self
          end

          #
          # Adds another clause, using the "is not one of" operator.
          #
          # @example create a rule that returns `true` if the name is "Patsy" and the country is not "gb"
          #     testData.flag("flag")
          #         .if_match(:name, 'Patsy')
          #         .and_not_match(:country, 'gb')
          #         .then_return(true)
          #
          # @param attribute [Symbol] the user attribute to match against
          # @param values [Array<Object>] values to compare to
          # @return [FlagRuleBuilder] the rule builder
          #
          def and_not_match(attribute, *values)
            @clauses.push(FlagRuleClause.new(
              attribute: attribute,
              op: 'in',
              values: values,
              negate: true
            ))
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
          # @return [FlagBuilder] the flag builder with this rule added
          #
          def then_return(variation)
            if LaunchDarkly::Impl::Util.is_bool variation then
              @variation = @flag_builder.variation_for_boolean(variation)
              @flag_builder.boolean_flag.add_rule(self)
            else
              @variation = variation
              @flag_builder.add_rule(self)
            end
          end

          # @private
          def build(ri)
            {
              id: 'rule' + ri.to_s,
              variation: @variation,
              clauses: @clauses.collect(&:to_h)
            }
          end
        end

        # @private
        def variation_for_boolean(variation)
          variation ? TRUE_VARIATION_INDEX : FALSE_VARIATION_INDEX
        end

        private

        TRUE_VARIATION_INDEX = 0
        FALSE_VARIATION_INDEX = 1

        def is_boolean_flag
          @variations.size == 2 &&
          @variations[TRUE_VARIATION_INDEX] == true &&
          @variations[FALSE_VARIATION_INDEX] == false
        end

        def deep_copy_hash(from)
          to = Hash.new
          from.each { |k, v| to[k] = v.clone }
          to
        end

        def deep_copy_array(from)
          to = Array.new
          from.each { |v| to.push(v.clone) }
          to
        end
      end
    end
  end
end
