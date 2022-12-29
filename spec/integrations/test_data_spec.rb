require "ldclient-rb"

module LaunchDarkly
  module Integrations
    describe 'TestData' do
      it 'is a valid datasource' do
        td = Integrations::TestData.data_source
        config = Config.new(send_events: false, data_source: td)
        client = LDClient.new('sdkKey', config)
        expect(config.feature_store.all(FEATURES)).to eql({})
        client.close
      end

      it 'initializes the feature store with existing flags' do
        td = Integrations::TestData.data_source
        td.update(td.flag('flag'))
        config = Config.new(send_events: false, data_source: td)
        client = LDClient.new('sdkKey', config)
        expect(config.feature_store.get(FEATURES, 'flag').data).to eql({
          key: 'flag',
          variations: [true, false],
          fallthrough: { variation: 0 },
          offVariation: 1,
          on: true,
          version: 1,
        })
        client.close
      end

      it 'updates the feature store with new flags' do
        td = Integrations::TestData.data_source
        td.update(td.flag('flag'))
        config = Config.new(send_events: false, data_source: td)
        client = LDClient.new('sdkKey', config)
        config2 = Config.new(send_events: false, data_source: td)
        client2 = LDClient.new('sdkKey', config2)

        expect(config.feature_store.get(FEATURES, 'flag').data).to eql({
          key: 'flag',
          variations: [true, false],
          fallthrough: { variation: 0 },
          offVariation: 1,
          on: true,
          version: 1,
        })
        expect(config2.feature_store.get(FEATURES, 'flag').data).to eql({
          key: 'flag',
          variations: [true, false],
          fallthrough: { variation: 0 },
          offVariation: 1,
          on: true,
          version: 1,
        })

        td.update(td.flag('flag').variation_for_all(false))

        expect(config.feature_store.get(FEATURES, 'flag').data).to eql({
          key: 'flag',
          variations: [true, false],
          fallthrough: { variation: 1 },
          offVariation: 1,
          on: true,
          version: 2,
        })
        expect(config2.feature_store.get(FEATURES, 'flag').data).to eql({
          key: 'flag',
          variations: [true, false],
          fallthrough: { variation: 1 },
          offVariation: 1,
          on: true,
          version: 2,
        })

        client.close
        client2.close
      end

      it 'can include preconfigured items' do
        td = Integrations::TestData.data_source
        td.use_preconfigured_flag({ key: 'my-flag', version: 1000, on: true })
        td.use_preconfigured_segment({ key: 'my-segment', version: 2000 })

        config = Config.new(send_events: false, data_source: td)
        client = LDClient.new('sdkKey', config)

        expect(config.feature_store.get(FEATURES, 'my-flag').data).to eql({
          key: 'my-flag', version: 1000, on: true
        })
        expect(config.feature_store.get(SEGMENTS, 'my-segment').data).to eql({
          key: 'my-segment', version: 2000
        })

        td.use_preconfigured_flag({ key: 'my-flag', on: false })

        expect(config.feature_store.get(FEATURES, 'my-flag').data).to eql({
          key: 'my-flag', version: 1001, on: false
        })

        td.use_preconfigured_segment({ key: 'my-segment', included: [ 'x' ] })

        expect(config.feature_store.get(SEGMENTS, 'my-segment').data).to eql({
          key: 'my-segment', version: 2001, included: [ 'x' ]
        })

        client.close
      end

      it 'TestData.flag defaults to a boolean flag' do
        td = TestData.new
        f = td.flag('flag').build(0)
        expect(f[:variations]).to eq([true, false])
        expect(f[:fallthrough][:variation]).to eq(0)
        expect(f[:offVariation]).to eq(1)
      end

      it 'TestData.flag returns a copy of the existing flag if it exists' do
        td = TestData.new
        td.update(td.flag('flag').variation_for_all(true))
        expect(td.flag('flag').build(0)[:fallthrough][:variation]).to eq(0)

        #modify the flag but dont call update
        td.flag('flag').variation_for_all(false).build(0)

        expect(td.flag('flag').build(0)[:fallthrough][:variation]).to eq(0)
      end

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
          expect(f[:offVariation]).to eq(0)
        end

        it 'can set a list of variations' do
          f = TestData::FlagBuilder.new('flag').variations(true, false).build(1)
          expect(f[:variations]).to eq([true, false])
        end

        it 'has the boolean_flag shortcut method' do
          f = TestData::FlagBuilder.new('flag').boolean_flag.build(1)
          expect(f[:variations]).to eq([true, false])
          expect(f[:fallthrough][:variation]).to eq(0)
          expect(f[:offVariation]).to eq(1)
        end

        it 'can handle boolean or index variation' do
          f = TestData::FlagBuilder.new('flag').off_variation(true).build(1)
          expect(f[:variations]).to eq([true, false])
          expect(f[:offVariation]).to eq(0)

          f2 = TestData::FlagBuilder.new('flag').fallthrough_variation(true).build(1)
          expect(f2[:variations]).to eq([true, false])
          expect(f2[:offVariation]).to eq(1)
        end

        it 'can set variation for all users' do
          f = TestData::FlagBuilder.new('flag').variation_for_all(true).build(1)
          expect(f[:rules]).to be_nil
          expect(f[:targets]).to be_nil
          expect(f[:fallthrough][:variation]).to be(0)
        end

        it 'clears existing rules when setting variation for all users' do
          f = TestData::FlagBuilder.new('flag')
                          .if_match('name', 'ben')
                          .then_return(false)
                          .variation_for_user('ben', false)
                          .variation_for_all(true).build(1)
          expect(f.keys).to_not include(:rules)
          expect(f.keys).to_not include(:targets)
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
          fb = TestData::FlagBuilder.new('flag').variation_for_all(true)
          expect(fb.build(0)).to eql(fb.clone.build(0))

          fcopy = fb.clone.variation_for_all(false).build(0)
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
                                        contextKind: "user",
                                        attribute: 'name',
                                        op: 'in',
                                        values: ['ben'],
                                        negate: false,
                                      },
                                      {
                                        contextKind: "user",
                                        attribute: 'country',
                                        op: 'in',
                                        values: ['fr'],
                                        negate: true,
                                      },
                                    ],
                                  }])
        end
      end
    end
  end
end
