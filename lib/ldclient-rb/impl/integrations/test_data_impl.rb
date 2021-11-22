require 'concurrent/atomics'
require 'ldclient-rb/interfaces'

module LaunchDarkly
  module Impl
    module Integrations
      class TestData
        def self.factory
          TestData.new
        end

        def arity
          2
        end

        def call(_, config)
          impl = DataSourceImpl.new(config.feature_store, self)
          @instances_lock.with_write_lock { @instances.push(impl) }
          impl
        end

        def make_init_data
            { FEATURES => @current_flags }
        end

        def closed_instance(instance)
          @instances_lock.with_write_lock { @instances.delete(instance) }
        end

        def initialize
          @flag_builders = Hash.new
          @current_flags = Hash.new
          @instances = Array.new
          @instances_lock = Concurrent::ReadWriteLock.new
          @lock = Concurrent::ReadWriteLock.new
        end

        def flag(flag_name)
          existing_builder = @lock.with_read_lock { @flag_builders[flag_name] }
          if existing_builder.nil? then
              FlagBuilder.new(flag_name).boolean_flag
          else
              existing_builder.clone
          end
        end

        def update(flag_builder)
          new_flag = nil
          @lock.with_write_lock do
            @flag_builders[flag_builder.key] = flag_builder
            version = 0
            if @current_flags[flag_builder.key] then
              version = @current_flags[flag_builder.key][:version]
            end
            new_flag = flag_builder.build(version+1)
            @current_flags[flag_builder.key] = new_flag
          end
          @instances_lock.with_read_lock do
            @instances.each do | instance |
              instance.upsert(new_flag)
            end
          end
        end

        class DataSourceImpl
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

          def on(aBool)
            @on = aBool
            self
          end

          def fallthrough_variation(variation)
            if [true,false].include? variation then
              boolean_flag.fallthrough_variation(variation_for_boolean(variation))
            else
              @fallthrough_variation = variation
              self
            end
          end

          def off_variation(variation)
            if [true,false].include? variation then
              boolean_flag.off_variation(variation_for_boolean(variation))
            else
              @off_variation = variation
              self
            end
          end

          def variations(*variations)
            @variations = variations
            self
          end

          def variation_for_all_users(variation)
            if [true,false].include? variation then
              boolean_flag.variation_for_all_users(variation_for_boolean(variation))
            else
              on(true).clear_rules.clear_user_targets.fallthrough_variation(variation)
            end
          end

          def value_for_all_users(value)
            variations(value).variation_for_all_users(0)
          end

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

          def if_match(attribute, *values)
            FlagRuleBuilder.new(self).and_match(attribute, *values)
          end
          def if_not_match(attribute, *values)
            FlagRuleBuilder.new(self).and_not_match(attribute, *values)
          end

          def clear_user_targets
            @targets = nil
            self
          end

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
              targets = Array.new
              @targets.each do | variation, values |
                targets.push({ variation: variation, values: values })
              end
              res[:targets] = targets
            end

            unless @rules.nil? then
              res[:rules] = @rules.each_with_index.collect { | rule, i | rule.build(i) }
            end

            res
          end

          class FlagRuleBuilder
            def initialize(flag_builder)
              @flag_builder = flag_builder
              @clauses = Array.new
            end

            def intialize_copy(other)
              super(other)
              @clauses = @clauses.clone
            end

            def and_match(attribute, *values)
              @clauses.push({
                attribute: attribute,
                op: 'in',
                values: values,
                negate: false
              })
              self
            end

            def and_not_match(attribute, *values)
              @clauses.push({
                attribute: attribute,
                op: 'in',
                values: values,
                negate: true
              })
              self
            end

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
                clauses: @clauses.clone
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
