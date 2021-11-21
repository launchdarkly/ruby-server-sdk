
module LaunchDarkly
  module Impl
    module Integrations
      class TestData
        class FlagBuilder
          private
            TRUE_VARIATION_INDEX = 0
            FALSE_VARIATION_INDEX = 1

            def is_boolean_flag
              @variations.size == 2 &&
              @variations[TRUE_VARIATION_INDEX] == true &&
              @variations[FALSE_VARIATION_INDEX] == false
            end

            def variation_for_boolean(variation)
              variation ? TRUE_VARIATION_INDEX : FALSE_VARIATION_INDEX
            end

            def set_rules(rules)
              self
            end

            def set_targets(rules)
              self
            end

          public
            def initialize(key, **args)
              @key = key
              @on = args[:on] || true
              @variations = args[:variations] || []
              @off_variation = args[:off_variation]
              @fallthrough_variation = args[:fallthrough_variation]
              @rules = args[:rules]
              @targets = args[:targets]
            end

            def copy
              FlagBuilder.new @key,
                          on: @on,
                          variations: @variations.clone,
                          off_variation: @off_variation,
                          fallthrough_variation: @fallthrough_variation,
                          rules: @rules,
                          targets: @targets
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
                on(true).fallthrough_variation(variation)
              end
            end

            def value_for_all_users(value)
              variations(value).variation_for_all_users(0)
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
              {
                key: @key,
                version: version,
                on: @on,
                off_variation: @off_variation,
                fallthrough: { variation: @fallthrough_variation },
                variations: @variations
              }
            end
        end
      end
    end
  end
end
