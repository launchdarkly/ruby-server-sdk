require "ldclient-rb/integrations/test_data"
require "spec_helper"

module LaunchDarkly
  module Integrations
    describe 'TestData' do
      def boolean_flag_hash(key, version, overrides = {})
        {
          key: key,
          version: version,
          on: true,
          variations: [true, false],
          prerequisites: [],
          salt: '',
          offVariation: 1,
          fallthrough: { variation: 0 },
        }.merge(overrides)
      end

      it 'flag defaults to a boolean flag' do
        td = TestData.data_source
        expect(td.flag('flag').build(1)).to eql(boolean_flag_hash('flag', 1))
      end

      it 'flag returns a copy of the stored builder' do
        td = TestData.data_source
        td.update(td.flag('flag').variation_for_all(true))
        expect(td.flag('flag').build(1)[:fallthrough]).to eql({ variation: 0 })

        td.flag('flag').variation_for_all(false).if_match('name', 'ben').then_return(true)

        expect(td.flag('flag').build(1)).to eql(boolean_flag_hash('flag', 1))
      end

      it 'update gives a new flag version 1' do
        td = TestData.data_source
        td.update(td.flag('flag'))
        expect(td.make_init_data[:flags][:flag]).to eql(boolean_flag_hash('flag', 1))
      end

      it 'update increments the version of an existing flag' do
        td = TestData.data_source
        td.update(td.flag('flag'))
        td.update(td.flag('flag').variation_for_all(false))
        expect(td.make_init_data[:flags][:flag]).to eql(boolean_flag_hash('flag', 2, fallthrough: { variation: 1 }))

        td.update(td.flag('flag').on(false))
        expect(td.make_init_data[:flags][:flag]).to eql(
          boolean_flag_hash('flag', 3, on: false, fallthrough: { variation: 1 })
        )
      end

      it 'update does not store later changes to the builder' do
        td = TestData.data_source
        builder = td.flag('flag')
        td.update(builder)
        builder.variation_for_all(false)

        expect(td.make_init_data[:flags][:flag]).to eql(boolean_flag_hash('flag', 1))
        expect(td.flag('flag').build(1)).to eql(boolean_flag_hash('flag', 1))
      end

      describe 'FlagBuilder' do
        it 'returns its flag key' do
          expect(TestData.data_source.flag('flag').key).to eq('flag')
        end

        it 'defaults to targeting on with the key and version' do
          f = TestData::FlagBuilder.new('flag').build(1)
          expect(f).to eql({
            key: 'flag',
            version: 1,
            on: true,
            variations: [],
            prerequisites: [],
            salt: '',
          })
        end

        it 'can set targeting off' do
          f = TestData::FlagBuilder.new('flag').on(false).build(1)
          expect(f[:on]).to eq(false)
        end

        it 'can set targeting on' do
          f = TestData::FlagBuilder.new('flag').on(false).on(true).build(1)
          expect(f[:on]).to eq(true)
        end

        it 'can set the fallthrough variation by index' do
          f = TestData::FlagBuilder.new('flag').fallthrough_variation(2).build(1)
          expect(f[:fallthrough]).to eql({ variation: 2 })
          expect(f[:variations]).to eql([])
          expect(f.keys).to_not include(:offVariation)
        end

        it 'can set the off variation by index' do
          f = TestData::FlagBuilder.new('flag').off_variation(2).build(1)
          expect(f[:offVariation]).to eq(2)
          expect(f[:variations]).to eql([])
          expect(f.keys).to_not include(:fallthrough)
        end

        it 'can set a list of variations' do
          f = TestData::FlagBuilder.new('flag').variations('red', 'green', 'blue').build(1)
          expect(f[:variations]).to eql(%w[red green blue])
        end

        it 'has the boolean_flag shortcut method' do
          f = TestData::FlagBuilder.new('flag').boolean_flag.build(1)
          expect(f).to eql(boolean_flag_hash('flag', 1))
        end

        it 'boolean_flag keeps the settings of a flag that is already boolean' do
          f = TestData::FlagBuilder.new('flag').boolean_flag.off_variation(0).fallthrough_variation(1)
                                       .boolean_flag.build(1)
          expect(f).to eql(boolean_flag_hash('flag', 1, offVariation: 0, fallthrough: { variation: 1 }))
        end

        it 'off_variation with a boolean changes the flag to a boolean flag' do
          f = TestData::FlagBuilder.new('flag').variations('a', 'b', 'c').off_variation(true).build(1)
          expect(f).to eql(boolean_flag_hash('flag', 1, offVariation: 0))

          f2 = TestData::FlagBuilder.new('flag').off_variation(false).build(1)
          expect(f2).to eql(boolean_flag_hash('flag', 1))
        end

        it 'fallthrough_variation with a boolean changes the flag to a boolean flag' do
          f = TestData::FlagBuilder.new('flag').variations('a', 'b', 'c').fallthrough_variation(false).build(1)
          expect(f).to eql(boolean_flag_hash('flag', 1, fallthrough: { variation: 1 }))

          f2 = TestData::FlagBuilder.new('flag').fallthrough_variation(true).build(1)
          expect(f2).to eql(boolean_flag_hash('flag', 1))
        end

        it 'can set the variation for all contexts with a boolean' do
          f = TestData::FlagBuilder.new('flag').on(false).variation_for_all(false).build(1)
          expect(f).to eql(boolean_flag_hash('flag', 1, fallthrough: { variation: 1 }))
        end

        it 'can set the variation for all contexts with an index' do
          f = TestData::FlagBuilder.new('flag').variations('a', 'b', 'c').off_variation(0).on(false)
                                       .variation_for_all(2).build(1)
          expect(f).to eql({
            key: 'flag',
            version: 1,
            on: true,
            variations: %w[a b c],
            prerequisites: [],
            salt: '',
            offVariation: 0,
            fallthrough: { variation: 2 },
          })
        end

        it 'clears existing rules and targets when setting the variation for all contexts' do
          f = TestData::FlagBuilder.new('flag')
                                       .if_match('name', 'ben')
                                       .then_return(false)
                                       .variation_for_user('ben', false)
                                       .variation_for_key('org', 'acme', true)
                                       .variation_for_all(true)
                                       .build(1)
          expect(f).to eql(boolean_flag_hash('flag', 1))
        end

        it 'can set a single value for all contexts' do
          f = TestData::FlagBuilder.new('flag')
                                       .boolean_flag
                                       .if_match('name', 'ben')
                                       .then_return(false)
                                       .variation_for_user('ben', false)
                                       .on(false)
                                       .value_for_all('x')
                                       .build(1)
          expect(f[:on]).to eq(true)
          expect(f[:variations]).to eql(['x'])
          expect(f[:fallthrough]).to eql({ variation: 0 })
          expect(f.keys).to_not include(:rules, :targets, :contextTargets)
        end

        it 'can set a variation for a user key with a boolean' do
          f = TestData::FlagBuilder.new('flag').variation_for_user('ben', false).build(1)
          expect(f[:variations]).to eql([true, false])
          expect(f[:targets]).to eql([{ variation: 1, values: ['ben'] }])
          expect(f[:contextTargets]).to eql([{ contextKind: 'user', variation: 1, values: [] }])
        end

        it 'can set a variation for a user key with an index' do
          f = TestData::FlagBuilder.new('flag').variations('a', 'b', 'c')
                                       .variation_for_user('ben', 2)
                                       .variation_for_user('amy', 2)
                                       .build(1)
          expect(f[:variations]).to eql(%w[a b c])
          expect(f[:targets]).to eql([{ variation: 2, values: %w[amy ben] }])
          expect(f[:contextTargets]).to eql([{ contextKind: 'user', variation: 2, values: [] }])
        end

        it 'can set a variation for a key of another context kind' do
          f = TestData::FlagBuilder.new('flag').variation_for_key('org', 'acme', true).build(1)
          expect(f.keys).to_not include(:targets)
          expect(f[:contextTargets]).to eql([{ contextKind: 'org', variation: 0, values: ['acme'] }])
        end

        it 'moves a key to the new variation when its variation changes' do
          f = TestData::FlagBuilder.new('flag')
                                       .variation_for_user('ben', false)
                                       .variation_for_user('ben', true)
                                       .build(1)
          expect(f[:targets]).to contain_exactly(
            { variation: 1, values: [] },
            { variation: 0, values: ['ben'] }
          )
        end

        it 'can clear targets' do
          f = TestData::FlagBuilder.new('flag')
                                       .variation_for_user('ben', false)
                                       .variation_for_key('org', 'acme', true)
                                       .clear_targets
                                       .build(1)
          expect(f).to eql(boolean_flag_hash('flag', 1))
        end

        it 'clone gives an independent copy of the targets' do
          f = TestData::FlagBuilder.new('flag').variation_for_user('ben', false)
          f2 = f.clone.variation_for_user('ben', true).variation_for_user('amy', false)

          expect(f.build(1)[:targets]).to eql([{ variation: 1, values: ['ben'] }])
          expect(f2.build(1)[:targets]).to contain_exactly(
            { variation: 1, values: ['amy'] },
            { variation: 0, values: ['ben'] }
          )
        end

        it 'dup gives an independent copy of the settings' do
          fb = TestData::FlagBuilder.new('flag').variation_for_all(true)
          expect(fb.dup.build(1)).to eql(fb.build(1))

          fcopy = fb.dup.variation_for_all(false).build(1)
          f = fb.build(1)
          expect(f[:fallthrough]).to eql({ variation: 0 })
          expect(fcopy[:fallthrough]).to eql({ variation: 1 })
        end

        it 'clone gives an independent copy of the variations' do
          fb = TestData::FlagBuilder.new('flag').variations('a', 'b')
          fb.clone.build(1)[:variations] << 'c'
          expect(fb.build(1)[:variations]).to eql(%w[a b])
        end

        it 'clone gives an independent copy of the rules' do
          fb = TestData::FlagBuilder.new('flag').if_match('name', 'ben').then_return(true)
          fcopy = fb.clone.if_match('name', 'amy').then_return(false)

          expect(fb.build(1)[:rules].length).to eq(1)
          expect(fcopy.build(1)[:rules].length).to eq(2)

          fcopy.clear_rules
          expect(fb.build(1)[:rules].length).to eq(1)
        end

        describe 'rules' do
          def clause(attribute, values, negate, context_kind = 'user')
            { contextKind: context_kind, attribute: attribute, op: 'in', values: values, negate: negate }
          end

          it 'can build a rule with if_match' do
            f = TestData::FlagBuilder.new('flag').if_match('name', 'ben', 'amy').then_return(true).build(1)
            expect(f[:rules]).to eql([
                                       { id: 'rule0', variation: 0, clauses: [clause('name', %w[ben amy], false)] },
                                     ])
          end

          it 'can build a rule with if_not_match' do
            f = TestData::FlagBuilder.new('flag').if_not_match('name', 'ben').then_return(false).build(1)
            expect(f[:rules]).to eql([
                                       { id: 'rule0', variation: 1, clauses: [clause('name', ['ben'], true)] },
                                     ])
          end

          it 'can build a rule with if_match_context' do
            f = TestData::FlagBuilder.new('flag').if_match_context('org', 'name', 'acme').then_return(true).build(1)
            expect(f[:rules]).to eql([
                                       { id: 'rule0', variation: 0, clauses: [clause('name', ['acme'], false, 'org')] },
                                     ])
          end

          it 'can build a rule with if_not_match_context' do
            f = TestData::FlagBuilder.new('flag').if_not_match_context('org', 'name', 'acme').then_return(true)
                                         .build(1)
            expect(f[:rules]).to eql([
                                       { id: 'rule0', variation: 0, clauses: [clause('name', ['acme'], true, 'org')] },
                                     ])
          end

          it 'can add clauses with and_match and and_not_match' do
            f = TestData::FlagBuilder.new('flag')
                                         .if_match('name', 'ben')
                                         .and_match('country', 'us')
                                         .and_not_match('state', 'ca')
                                         .then_return(true)
                                         .build(1)
            expect(f[:rules]).to eql([
                                       {
                                         id: 'rule0',
                                         variation: 0,
                                         clauses: [
                                           clause('name', ['ben'], false),
                                           clause('country', ['us'], false),
                                           clause('state', ['ca'], true),
                                         ],
                                       },
                                     ])
          end

          it 'can add clauses with and_match_context and and_not_match_context' do
            f = TestData::FlagBuilder.new('flag')
                                         .if_match('name', 'ben')
                                         .and_match_context('org', 'name', 'acme')
                                         .and_not_match_context('org', 'country', 'fr')
                                         .then_return(true)
                                         .build(1)
            expect(f[:rules]).to eql([
                                       {
                                         id: 'rule0',
                                         variation: 0,
                                         clauses: [
                                           clause('name', ['ben'], false),
                                           clause('name', ['acme'], false, 'org'),
                                           clause('country', ['fr'], true, 'org'),
                                         ],
                                       },
                                     ])
          end

          it 'then_return with a boolean changes the flag to a boolean flag' do
            f = TestData::FlagBuilder.new('flag').variations('a', 'b', 'c').if_match('name', 'ben')
                                         .then_return(false).build(1)
            expect(f).to eql(boolean_flag_hash('flag', 1, rules: [
                                                 { id: 'rule0', variation: 1, clauses: [clause('name', ['ben'], false)] },
                                               ]))
          end

          it 'then_return with an index keeps the variations' do
            f = TestData::FlagBuilder.new('flag').variations('a', 'b', 'c').if_match('name', 'ben')
                                         .then_return(2).build(1)
            expect(f[:variations]).to eql(%w[a b c])
            expect(f[:rules]).to eql([
                                       { id: 'rule0', variation: 2, clauses: [clause('name', ['ben'], false)] },
                                     ])
          end

          it 'numbers the rule ids in order' do
            f = TestData::FlagBuilder.new('flag')
                                         .if_match('name', 'ben').then_return(true)
                                         .if_not_match('name', 'amy').then_return(false)
                                         .build(1)
            expect(f[:rules]).to eql([
                                       { id: 'rule0', variation: 0, clauses: [clause('name', ['ben'], false)] },
              { id: 'rule1', variation: 1, clauses: [clause('name', ['amy'], true)] },
                                     ])
          end

          it 'can clear rules' do
            f = TestData::FlagBuilder.new('flag')
                                         .if_match('name', 'ben').then_return(true)
                                         .if_match('name', 'amy').then_return(false)
                                         .clear_rules
                                         .build(1)
            expect(f).to eql(boolean_flag_hash('flag', 1))
          end
        end
      end
    end
  end
end
