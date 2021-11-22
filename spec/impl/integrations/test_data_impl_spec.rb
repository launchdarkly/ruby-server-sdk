require "ldclient-rb/impl/integrations/test_data_impl"

module LaunchDarkly
  module Impl
    module Integrations
      describe 'TestData' do
        describe 'FlagBuilder' do

          it 'defaults to targeting on and sets the flag key' do
            f = TestData::FlagBuilder.new('flag').build(1)
            expect(f[:key]).to eq('flag')
            expect(f[:version]).to eq(1)
            expect(f[:on]).to eq(true)
            expect(f[:variations]).to be_empty
          end

          it 'can set targeting off' do
            f = TestData::FlagBuilder.new('flag').on(false).build(1)
            expect(f[:on]).to eq(false)
          end

          it 'can set fallthrough variation' do
            f = TestData::FlagBuilder.new('flag').fallthrough_variation(0).build(1)
            expect(f[:fallthrough][:variation]).to eq(0)
          end

          it 'can set variation for when targeting is off' do
            f = TestData::FlagBuilder.new('flag').off_variation(0).build(1)
            expect(f[:off_variation]).to eq(0)
          end

          it 'can set a list of variations' do
            f = TestData::FlagBuilder.new('flag').variations(true, false).build(1)
            expect(f[:variations]).to eq([true, false])
          end

          it 'has the boolean_flag shortcut method' do
            f = TestData::FlagBuilder.new('flag').boolean_flag.build(1)
            expect(f[:variations]).to eq([true, false])
            expect(f[:fallthrough][:variation]).to eq(0)
            expect(f[:off_variation]).to eq(1)
          end

          it 'can handle boolean or index variation' do
            f = TestData::FlagBuilder.new('flag').off_variation(true).build(1)
            expect(f[:variations]).to eq([true, false])
            expect(f[:off_variation]).to eq(0)

            f2 = TestData::FlagBuilder.new('flag').fallthrough_variation(true).build(1)
            expect(f2[:variations]).to eq([true, false])
            expect(f2[:off_variation]).to eq(1)
          end

          it 'can set variation for all users' do
            f = TestData::FlagBuilder.new('flag').variation_for_all_users(true).build(1)
            expect(f[:rules]).to be_nil
            expect(f[:targets]).to be_nil
            expect(f[:fallthrough][:variation]).to be(0)
          end

          it 'clears existing rules when setting variation for all users' do
            f = TestData::FlagBuilder.new('flag')
                            .if_match('name', 'ben')
                            .then_return(false)
                            .variation_for_user('ben', false)
                            .variation_for_all_users(true).build(1)
            expect(f[:rules]).to be_nil
            expect(f[:targets]).to be_nil
            expect(f[:fallthrough][:variation]).to be(0)
          end

          it 'can set a variation for a specific user' do
            f = TestData::FlagBuilder.new('flag')
                                     .variation_for_user('ben', false)
            f2 = f.clone.variation_for_user('ben', true)
            expect(f.build(0)[:targets]).to eql([ { variation: 1, values: ['ben'] } ])
            expect(f2.build(1)[:targets]).to_not include({ variation: 1, values: ['ben'] })
            expect(f2.build(1)[:targets]).to include({ variation: 0, values: ['ben'] })
          end

          it 'can make an immutable copy of its self' do
            fb = TestData::FlagBuilder.new('flag').variation_for_all_users(true)
            expect(fb.build(0)).to eql(fb.clone.build(0))

            fcopy = fb.clone.variation_for_all_users(false).build(0)
            f = fb.build(0)

            expect(f[:key]).to eql(fcopy[:key])
            expect(f[:variations]).to eql(fcopy[:variations])
            expect(f[:fallthrough][:variation]).to be(0)
            expect(fcopy[:fallthrough][:variation]).to be(1)
          end

          it 'can build rules based on attributes' do
            f = TestData::FlagBuilder.new('flag')
                                      .if_match('name', 'ben')
                                      .and_not_match('country', 'fr')
                                      .then_return(true)
                                      .build(1)
            expect(f[:rules]).to eql([{
                                      id: "rule0",
                                      variation: 0,
                                      clauses: [{
                                          attribute: 'name',
                                          op: 'in',
                                          values: ['ben'],
                                          negate: false,
                                        },
                                        {
                                          attribute: 'country',
                                          op: 'in',
                                          values: ['fr'],
                                          negate: true,
                                        }
                                      ]
                                    }])
          end
        end
      end
    end
  end
end
