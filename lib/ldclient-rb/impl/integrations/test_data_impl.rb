require 'concurrent/atomics'
require 'ldclient-rb/interfaces'

module LaunchDarkly
  module Impl
    module Integrations
      class TestDataImpl
        def initialize
          @flag_builders = Hash.new
          @current_flags = Hash.new
          @instances = Array.new
          @instances_lock = Concurrent::ReadWriteLock.new
          @lock = Concurrent::ReadWriteLock.new
        end

        #
        # Called internally by the SDK to determine what arguments to pass to call
        # You do not need to call this method.
        #
        def arity
          2
        end

        #
        # Called internally by the SDK to associate this test data source with an {@code LDClient} instance.
        # You do not need to call this method.
        #
        def call(_, config)
          impl = TestDataSource.new(config.feature_store, self)
          @instances_lock.with_write_lock { @instances.push(impl) }
          impl
        end

        #
        # Creates or copies a {@link FlagBuilder} for building a test flag configuration.
        # <p>
        # If this flag key has already been defined in this {@code TestDataImpl} instance, then the builder
        # starts with the same configuration that was last provided for this flag.
        # <p>
        # Otherwise, it starts with a new default configuration in which the flag has {@code true} and
        # {@code false} variations, is {@code true} for all users when targeting is turned on and
        # {@code false} otherwise, and currently has targeting turned on. You can change any of those
        # properties, and provide more complex behavior, using the {@link FlagBuilder} methods.
        # <p>
        # Once you have set the desired configuration, pass the builder to {@link #update(FlagBuilder)}.
        #
        # @param key the flag key
        # @return a flag configuration builder
        # @see #update(FlagBuilder)
        #
        def flag(key)
          existing_builder = @lock.with_read_lock { @flag_builders[key] }
          if existing_builder.nil? then
              FlagBuilder.new(key).boolean_flag
          else
              existing_builder.clone
          end
        end

        #
        # Updates the test data with the specified flag configuration.
        # <p>
        # This has the same effect as if a flag were added or modified on the LaunchDarkly dashboard.
        # It immediately propagates the flag change to any {@code LDClient} instance(s) that you have
        # already configured to use this {@code TestDataImpl}. If no {@code LDClient} has been started yet,
        # it simply adds this flag to the test data which will be provided to any {@code LDClient} that
        # you subsequently configure.
        # <p>
        # Any subsequent changes to this {@link FlagBuilder} instance do not affect the test data,
        # unless you call {@link #update(FlagBuilder)} again.
        #
        # @param flag_builder a flag configuration builder
        # @return the same {@code TestDataImpl} instance
        # @see #flag(String)
        #
        def update(flag_builder)
          new_flag = nil
          @lock.with_write_lock do
            @flag_builders[flag_builder.key] = flag_builder
            version = 0
            flag_key = flag_builder.key.to_sym
            if @current_flags[flag_key] then
              version = @current_flags[flag_key][:version]
            end
            new_flag = flag_builder.build(version+1)
            @current_flags[flag_key] = new_flag
          end
          @instances_lock.with_read_lock do
            @instances.each do | instance |
              instance.upsert(new_flag)
            end
          end
        end

        def make_init_data
            { FEATURES => @current_flags }
        end

        def closed_instance(instance)
          @instances_lock.with_write_lock { @instances.delete(instance) }
        end

        class TestDataSource
          include LaunchDarkly::Interfaces::DataSource

          def initialize(feature_store, test_data)
            @feature_store = feature_store
            @test_data = test_data
          end

          def initialized?
            true
          end

          def start
            ready = Concurrent::Event.new
            ready.set
            init_data = @test_data.make_init_data
            @feature_store.init(init_data)
            ready
          end

          def stop
            @test_data.closed_instance(self)
          end

          def upsert(new_flag)
            @feature_store.upsert(FEATURES, new_flag)
          end
        end

        class DeepCopyHash < Hash
          def initialize_copy(other)
            other.each do | key, value |
              self[key] = value.clone
            end
          end
        end

        class DeepCopyArray < Array
          def initialize_copy(other)
            other.each do | value |
              self.push(value.clone)
            end
          end
        end

        #
        # A builder for feature flag configurations to be used with {@link TestDataImpl}.
        #
        # @see TestDataImpl#flag(String)
        # @see TestDataImpl#update(FlagBuilder)
        #
        class FlagBuilder
          attr_reader :key

          def initialize(key)
            @key = key
            @on = true
            @variations = []
          end

          def initialize_copy(other)
            super(other)
            @variations = @variations.clone
            @rules = @rules.nil? ? nil : @rules.clone
            @targets = @targets.nil? ? nil : @targets.clone
          end

          #
          # Sets targeting to be on or off for this flag.
          # <p>
          # The effect of this depends on the rest of the flag configuration, just as it does on the
          # real LaunchDarkly dashboard. In the default configuration that you get from calling
          # {@link TestDataImpl#flag(String)} with a new flag key, the flag will return {@code false}
          # whenever targeting is off, and {@code true} when targeting is on.
          #
          # @param on true if targeting should be on
          # @return the builder
          #
          def on(on)
            @on = on
            self
          end

          #
          # Specifies the fallthrough variation. The fallthrough is the value
          # that is returned if targeting is on and the user was not matched by a more specific
          # target or rule.
          # <p>
          # If the flag was previously configured with other variations and the variation specified is a boolean,
          # this also changes it to a boolean flag.
          #
          # @param variation true or false or the desired fallthrough variation index:
          #                  0 for the first, 1 for the second, etc.
          # @return the builder
          #
          def fallthrough_variation(variation)
            if [true,false].include? variation then
              boolean_flag.fallthrough_variation(variation_for_boolean(variation))
            else
              @fallthrough_variation = variation
              self
            end
          end

          #
          # Specifies the off variation for a flag. This is the variation that is returned
          # whenever targeting is off.
          # <p>
          # If the flag was previously configured with other variations and the variation specified is a boolean,
          # this also changes it to a boolean flag.
          #
          # @param variation true or false or the desired off variation index:
          #                  0 for the first, 1 for the second, etc.
          # @return the builder
          #
          def off_variation(variation)
            if [true,false].include? variation then
              boolean_flag.off_variation(variation_for_boolean(variation))
            else
              @off_variation = variation
              self
            end
          end

          #
          # Changes the allowable variation values for the flag.
          # <p>
          # The value may be of any valid JSON type. For instance, a boolean flag
          # normally has {@code true, false}; a string-valued flag might have
          # {@code 'red', 'green'}; etc.
          #
          # @param variations the desired variations
          # @return the builder
          #
          def variations(*variations)
            @variations = variations
            self
          end

          #
          # Sets the flag to always return the specified variation for all users.
          # <p>
          # The variation is specified, Targeting is switched on, and any existing targets or rules are removed.
          # The fallthrough variation is set to the specified value. The off variation is left unchanged.
          # <p>
          # If the flag was previously configured with other variations and the variation specified is a boolean,
          # this also changes it to a boolean flag.
          #
          # @param variation true or false or the desired variation index to return:
          #                  0 for the first, 1 for the second, etc.
          # @return the builder
          #
          def variation_for_all_users(variation)
            if [true,false].include? variation then
              boolean_flag.variation_for_all_users(variation_for_boolean(variation))
            else
              on(true).clear_rules.clear_user_targets.fallthrough_variation(variation)
            end
          end

          #
          # Sets the flag to always return the specified variation value for all users.
          # <p>
          # The value may be of any valid JSON type. This method changes the
          # flag to have only a single variation, which is this value, and to return the same
          # variation regardless of whether targeting is on or off. Any existing targets or rules
          # are removed.
          #
          # @param value the desired value to be returned for all users
          # @return the builder
          #
          def value_for_all_users(value)
            variations(value).variation_for_all_users(0)
          end

          #
          # Sets the flag to return the specified variation for a specific user key when targeting
          # is on.
          # <p>
          # This has no effect when targeting is turned off for the flag.
          # <p>
          # If the flag was previously configured with other variations and the variation specified is a boolean,
          # this also changes it to a boolean flag.
          #
          # @param user_key a user key
          # @param variation true or false or the desired variation index to return:
          #                  0 for the first, 1 for the second, etc.
          # @return the builder
          #
          def variation_for_user(user_key, variation)
            if [true,false].include? variation then
              boolean_flag.variation_for_user(user_key, variation_for_boolean(variation))
            else
              if @targets.nil? then
                @targets = DeepCopyHash.new
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
          # <p>
          # For example, this creates a rule that returns {@code true} if the name is "Patsy" or "Edina":
          #
          # <pre><code>
          #     testData.flag("flag")
          #         .if_match(:name, 'Patsy', 'Edina')
          #         .then_return(true);
          # </code></pre>
          #
          # @param attribute the user attribute to match against
          # @param values values to compare to
          # @return a {@link FlagRuleBuilder}; call {@link FlagRuleBuilder#then_return(boolean|int)}
          #   to finish the rule, or add more tests with another method like
          #   {@link FlagRuleBuilder#and_match(UserAttribute, LDValue...)}
          #
          def if_match(attribute, *values)
            FlagRuleBuilder.new(self).and_match(attribute, *values)
          end

          #
          # Starts defining a flag rule, using the "is not one of" operator.
          # <p>
          # For example, this creates a rule that returns {@code true} if the name is neither "Saffron" nor "Bubble":
          #
          # <pre><code>
          #     testData.flag("flag")
          #         .if_not_match(:name, 'Saffron', 'Bubble')
          #         .then_return(true)
          # </code></pre>
          #
          # @param attribute the user attribute to match against
          # @param values values to compare to
          # @return a {@link FlagRuleBuilder}; call {@link FlagRuleBuilder#then_return(boolean|int)}
          #   to finish the rule, or add more tests with another method like
          #   {@link FlagRuleBuilder#and_match(UserAttribute, value...)}
          #
          def if_not_match(attribute, *values)
            FlagRuleBuilder.new(self).and_not_match(attribute, *values)
          end

          #
          # Removes any existing user targets from the flag. This undoes the effect of methods like
          # {@link #variation_for_user}
          #
          # @return the same builder
          #
          def clear_user_targets
            @targets = nil
            self
          end

          #
          # Removes any existing rules from the flag. This undoes the effect of methods like
          # {@link #if_match}
          #
          # @return the same builder
          #
          def clear_rules
            @rules = nil
            self
          end

          def add_rule(rule)
            if @rules.nil? then
              @rules = DeepCopyArray.new
            end
            @rules.push(rule)
            self
          end

          #
          #  A shortcut for setting the flag to use the standard boolean configuration.
          #  <p>
          #  This is the default for all new flags created with {@link TestDataImpl#flag(String)}. The flag
          #  will have two variations, {@code true} and {@code false} (in that order); it will return
          #  {@code false} whenever targeting is off, and {@code true} when targeting is on if no other
          #  settings specify otherwise.
          #
          #  @return the builder
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

          def build(version)
            res = { key: @key,
                    version: version,
                    on: @on,
                  }

            unless @off_variation.nil? then
              res[:off_variation] = @off_variation
            end

            unless @fallthrough_variation.nil? then
              res[:fallthrough] = { variation: @fallthrough_variation }
            end

            unless @variations.nil? then
              res[:variations] = @variations
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
          # A builder for feature flag rules to be used with {@link FlagBuilder}.
          # <p>
          # In the LaunchDarkly model, a flag can have any number of rules, and a rule can have any number of
          # clauses. A clause is an individual test such as "name is 'X'". A rule matches a user if all of the
          # rule's clauses match the user.
          # <p>
          # To start defining a rule, use one of the flag builder's matching methods such as
          # {@link FlagBuilder#if_match}. This defines the first clause for the rule.
          # Optionally, you may add more clauses with the rule builder's methods such as
          # {@link #and_match} or {@link #and_not_match}.
          # Finally, call {@link #then_return} to finish defining the rule.
          #
          class FlagRuleBuilder
            FlagRuleClause = Struct.new(:attribute, :op, :values, :negate, keyword_init: true)

            def initialize(flag_builder)
              @flag_builder = flag_builder
              @clauses = Array.new
            end

            def intialize_copy(other)
              super(other)
              @clauses = @clauses.clone
            end

            #
            # Adds another clause, using the "is one of" operator.
            # <p>
            # For example, this creates a rule that returns {@code true} if the name is "Patsy" and the
            # country is "gb":
            #
            # <pre><code>
            #     testData.flag("flag")
            #         .if_match(:name, 'Patsy')
            #         .and_match(:country, 'gb')
            #         .then_return(true)
            # </code></pre>
            #
            # @param attribute the user attribute to match against
            # @param values values to compare to
            # @return the rule builder
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
            # <p>
            # For example, this creates a rule that returns {@code true} if the name is "Patsy" and the
            # country is not "gb":
            #
            # <pre><code>
            #     testData.flag("flag")
            #         .if_match(:name, 'Patsy')
            #         .and_not_match(:country, 'gb')
            #         .then_return(true)
            # </code></pre>
            #
            # @param attribute the user attribute to match against
            # @param values values to compare to
            # @return the rule builder
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
            # <p>
            # If the flag was previously configured with other variations and the variation specified is a boolean,
            # this also changes it to a boolean flag.
            #
            # @param variation true or false or the desired variation index:
            #                  0 for the first, 1 for the second, etc.
            # @result the flag builder with this rule added
            #
            def then_return(variation)
              if [true, false].include? variation then
                @variation = @flag_builder.variation_for_boolean(variation)
                @flag_builder.boolean_flag.add_rule(self)
              else
                @variation = variation
                @flag_builder.add_rule(self)
              end
            end

            def build(ri)
              {
                id: 'rule' + ri.to_s,
                variation: @variation,
                clauses: @clauses.collect(&:to_h)
              }
            end
          end

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

        end
      end
    end
  end
end
