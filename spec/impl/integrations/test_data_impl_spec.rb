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

          it 'can make an immutable copy of its self' do
            fb = TestData::FlagBuilder.new('flag').variation_for_all_users(true)
            fbcopy = fb.copy.variation_for_all_users(false)
            f = fb.build(0)
            fcopy = fbcopy.build(0)

            expect(f[:key]).to eql(fcopy[:key])
            expect(f[:variations]).to eql(fcopy[:variations])
            expect(f[:fallthrough][:variation]).to be(0)
            expect(fcopy[:fallthrough][:variation]).to be(1)
          end
        end
      end
    end
  end
end
