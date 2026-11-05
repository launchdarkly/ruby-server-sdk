require "ldclient-rb/integrations/test_data_v2"
require "ldclient-rb/impl/integrations/test_data/test_data_source_v2"
require "spec_helper"
require "json"
require "set"

module LaunchDarkly
  module Integrations
    describe 'TestDataV2' do
      it 'initializes with empty flags and segments' do
        td = TestDataV2.data_source
        init_data = td.make_init_data
        expect(init_data[:flags]).to eq({})
        expect(init_data[:segments]).to eq({})
      end

      it 'stores flags' do
        td = TestDataV2.data_source
        td.update(td.flag('myflag').variation_for_all(true))
        init_data = td.make_init_data
        expect(init_data[:flags].keys).to include(:myflag)
        expect(init_data[:flags][:myflag][:key]).to eq('myflag')
      end

      it 'stores preconfigured segments' do
        td = TestDataV2.data_source
        td.use_preconfigured_segment({ key: 'mysegment', version: 100, included: ['user1'] })
        init_data = td.make_init_data
        expect(init_data[:segments].keys).to include(:mysegment)
        expect(init_data[:segments][:mysegment][:key]).to eq('mysegment')
        expect(init_data[:segments][:mysegment][:version]).to eq(1)
        expect(init_data[:segments][:mysegment][:included]).to eq(['user1'])
      end

      it 'handles segments with string-keyed hashes' do
        td = TestDataV2.data_source
        # Use string keys instead of symbol keys
        td.use_preconfigured_segment({ 'key' => 'mysegment', 'version' => 100, 'included' => ['user1'], 'excluded' => ['user2'] })
        init_data = td.make_init_data
        expect(init_data[:segments].keys).to include(:mysegment)
        expect(init_data[:segments][:mysegment][:key]).to eq('mysegment')
        expect(init_data[:segments][:mysegment][:version]).to eq(1)
        expect(init_data[:segments][:mysegment][:included]).to eq(['user1'])
        expect(init_data[:segments][:mysegment][:excluded]).to eq(['user2'])
      end

      it 'increments segment version on update' do
        td = TestDataV2.data_source
        td.use_preconfigured_segment({ key: 'mysegment', version: 100 })
        td.use_preconfigured_segment({ key: 'mysegment', included: ['user2'] })
        init_data = td.make_init_data
        expect(init_data[:segments][:mysegment][:version]).to eq(2)
        expect(init_data[:segments][:mysegment][:included]).to eq(['user2'])
      end

      it 'stores preconfigured flags with their own version' do
        td = TestDataV2.data_source
        td.use_preconfigured_flag({ key: 'myflag', version: 100, on: true, variations: ['a'] })
        flag = td.make_init_data[:flags][:myflag]
        expect(flag[:key]).to eq('myflag')
        expect(flag[:version]).to eq(100)
        expect(flag[:variations]).to eq(['a'])
      end

      it 'gives a preconfigured flag with no version version 1' do
        td = TestDataV2.data_source
        td.use_preconfigured_flag({ 'key' => 'myflag', 'variations' => ['a'] })
        expect(td.make_init_data[:flags][:myflag][:version]).to eq(1)
      end

      it 'increments the version when a preconfigured flag replaces a flag' do
        td = TestDataV2.data_source
        td.use_preconfigured_flag({ key: 'myflag', version: 100, variations: ['a'] })
        td.use_preconfigured_flag({ key: 'myflag', version: 5, variations: ['b'] })
        flag = td.make_init_data[:flags][:myflag]
        expect(flag[:version]).to eq(101)
        expect(flag[:variations]).to eq(['b'])
      end

      it 'accepts a FeatureFlag model as a preconfigured flag' do
        td = TestDataV2.data_source
        model = LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'myflag', version: 3, variations: ['a'] })
        td.use_preconfigured_flag(model)
        expect(td.make_init_data[:flags][:myflag][:version]).to eq(3)
      end

      it 'starts a new flag builder after a preconfigured flag replaces a built flag' do
        td = TestDataV2.data_source
        td.update(td.flag('myflag').variations('x', 'y'))
        td.use_preconfigured_flag({ key: 'myflag', variations: ['a'] })
        expect(td.flag('myflag').build(1)[:variations]).to eq([true, false])
      end

      it 'sends a preconfigured flag to a running data source' do
        td = TestDataV2.data_source
        source = LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2.new(td)
        expect(source).to receive(:upsert_flag).with(hash_including(key: 'myflag', version: 7))
        td.use_preconfigured_flag({ key: 'myflag', version: 7, variations: ['a'] })
      end

      it 'keeps a provided version that is greater than the version of the flag it replaces' do
        td = TestDataV2.data_source
        td.use_preconfigured_flag({ key: 'myflag', version: 5, variations: ['a'] })
        td.use_preconfigured_flag({ key: 'myflag', version: 100, variations: ['b'] })
        expect(td.make_init_data[:flags][:myflag][:version]).to eq(100)
      end

      it 'gives a new preconfigured flag with version 0 version 1' do
        td = TestDataV2.data_source
        td.use_preconfigured_flag({ key: 'myflag', version: 0, variations: ['a'] })
        expect(td.make_init_data[:flags][:myflag][:version]).to eq(1)
      end

      it 'converts string keys at every level of a preconfigured flag to symbols' do
        td = TestDataV2.data_source
        flag_json = '{"key":"myflag","version":3,"on":true,"fallthrough":{"variation":0},"variations":["a"],' \
          '"rules":[{"id":"r","variation":0,"clauses":[{"attribute":"key","op":"in","values":["u"]}]}]}'
        td.use_preconfigured_flag(JSON.parse(flag_json))
        flag = td.make_init_data[:flags][:myflag]
        expect(flag[:fallthrough]).to eq({ variation: 0 })
        expect(flag[:rules][0][:clauses][0][:attribute]).to eq('key')
      end

      it 'accepts a preconfigured flag as a JSON string' do
        td = TestDataV2.data_source
        td.use_preconfigured_flag('{"key":"myflag","version":3,"variations":["a"]}')
        expect(td.make_init_data[:flags][:myflag][:version]).to eq(3)
      end

      it 'stores a copy of a preconfigured flag' do
        td = TestDataV2.data_source
        flag = { key: 'myflag', version: 1, fallthrough: { variation: 0 }, variations: ['a'] }
        td.use_preconfigured_flag(flag)
        flag[:fallthrough][:variation] = 1
        flag[:variations] << 'b'
        stored = td.make_init_data[:flags][:myflag]
        expect(stored[:fallthrough]).to eq({ variation: 0 })
        expect(stored[:variations]).to eq(['a'])
      end

      it 'does not change a stored flag when its rule builder changes later' do
        td = TestDataV2.data_source
        builder = td.flag('myflag')
        rule = builder.if_match('name', 'alice')
        rule.then_return(true)
        td.update(builder)
        rule.and_match('country', 'us')
        clauses = td.make_init_data[:flags][:myflag][:rules][0][:clauses]
        expect(clauses.map { |clause| clause[:attribute] }).to eq(['name'])
      end

      describe 'rejects an invalid preconfigured flag' do
        {
          'nil' => nil,
          'a value that is not a hash' => 42,
          'a hash without a key' => { version: 1 },
          'an empty key' => { key: '' },
          'a version that is not an integer' => { key: 'myflag', version: '100' },
          'malformed JSON' => '{not json',
          'a JSON value that is not an object' => '[1]',
          'a malformed prerequisite' => { key: 'myflag', version: 1, prerequisites: ['oops'] },
          'a value that is not a JSON value' => { key: 'myflag', variations: [Time.at(0)] },
          'a NaN value' => { key: 'myflag', variations: [Float::NAN] },
          'an infinite value' => { key: 'myflag', variations: [Float::INFINITY] },
          'the same key as a string and a symbol' => { key: 'myflag', 'key' => 'other' },
          'a hash key that is not a string or symbol' => { key: 'myflag', variations: [{ 1 => 'a' }] },
        }.each do |name, flag|
          it "with #{name}" do
            td = TestDataV2.data_source
            td.use_preconfigured_flag({ key: 'other', version: 1, variations: ['a'] })
            expect { td.use_preconfigured_flag(flag) }.to raise_error(ArgumentError)
            expect(td.make_init_data[:flags].keys).to eq([:other])
          end
        end
      end

      describe 'rejects an invalid preconfigured segment' do
        {
          'nil' => nil,
          'a hash without a key' => { version: 1 },
          'malformed JSON' => '{not json',
          'a malformed rule' => { key: 'myseg', rules: ['oops'] },
        }.each do |name, segment|
          it "with #{name}" do
            td = TestDataV2.data_source
            expect { td.use_preconfigured_segment(segment) }.to raise_error(ArgumentError)
            expect(td.make_init_data[:segments]).to eq({})
          end
        end
      end

      it 'rejects a preconfigured flag that is nested too deeply' do
        deep = 'a'
        150.times { deep = [deep] }
        td = TestDataV2.data_source
        expect { td.use_preconfigured_flag({ key: 'myflag', variations: [deep] }) }.to raise_error(ArgumentError)
      end

      it 'rejects a preconfigured flag that contains itself' do
        flag = { key: 'myflag', variations: [] }
        flag[:variations] << flag
        td = TestDataV2.data_source
        expect { td.use_preconfigured_flag(flag) }.to raise_error(ArgumentError)
      end

      it 'stores Set values of a preconfigured segment as arrays' do
        td = TestDataV2.data_source
        td.use_preconfigured_segment({ key: 'myseg', included: Set['u1', 'u2'] })
        expect(td.make_init_data[:segments][:myseg][:included]).to eq(%w[u1 u2])
      end

      it 'stores symbol values of a preconfigured flag as strings' do
        td = TestDataV2.data_source
        td.use_preconfigured_flag({ key: 'myflag', variations: [:a], rules: [{ id: 'r', variation: 0, clauses: [{ attribute: 'key', op: :in, values: ['u'] }] }] })
        flag = td.make_init_data[:flags][:myflag]
        expect(flag[:variations]).to eq(['a'])
        expect(flag[:rules][0][:clauses][0][:op]).to eq('in')
      end

      it 'converts string keys at every level of a preconfigured segment to symbols' do
        td = TestDataV2.data_source
        td.use_preconfigured_segment(JSON.parse('{"key":"myseg","rules":[{"id":"r","clauses":[{"attribute":"key","op":"in","values":["u"]}]}]}'))
        expect(td.make_init_data[:segments][:myseg][:rules][0][:clauses][0][:op]).to eq('in')
      end

      describe 'change delivery order' do
        # A data source instance that blocks inside the first delivery until the spec releases it.
        let(:delivered) { Queue.new }
        let(:release) { Queue.new }
        let(:instance) do
          delivered_versions = delivered
          release_first = release
          calls = 0
          inst = Object.new
          inst.define_singleton_method(:upsert_flag) do |flag|
            calls += 1
            release_first.pop if calls == 1
            delivered_versions << flag[:version]
          end
          inst
        end

        def expect_delivery_in_order
          td = TestDataV2.data_source
          td.add_instance(instance)
          first = Thread.new { yield td, 1 }
          second = nil
          begin
            deadline = Time.now + 5
            sleep 0.01 until first.status == 'sleep' || !first.alive? || Time.now > deadline
            expect(first.status).to eq('sleep')
            second = Thread.new { yield td, 2 }

            # The second change waits for the first change to finish its delivery.
            expect(second.join(0.2)).to be_nil
          ensure
            release << true
            [first, second].compact.each { |t| t.join(5) }
          end

          expect([delivered.pop(timeout: 1), delivered.pop(timeout: 1)]).to eq([1, 2])
        end

        it 'delivers flag updates in the order that they are made' do
          expect_delivery_in_order { |td, _| td.update(td.flag('myflag').variation_for_all(true)) }
        end

        it 'delivers preconfigured flags in the order that they are made' do
          expect_delivery_in_order { |td, n| td.use_preconfigured_flag({ key: 'myflag', version: n, variations: ['a'] }) }
        end
      end

      describe 'FlagBuilderV2 event and migration settings' do
        it 'omits the settings by default' do
          flag = TestDataV2.data_source.flag('myflag').build(1)
          expect(flag).not_to include(:migration, :samplingRatio, :excludeFromSummaries)
        end

        it 'includes migration settings' do
          settings = TestDataV2::FlagBuilderV2::FlagMigrationSettingsBuilder.new.check_ratio(10).build
          flag = TestDataV2.data_source.flag('myflag').migration_settings(settings).build(1)
          expect(flag[:migration]).to eq({ checkRatio: 10 })
        end

        it 'builds no migration settings for the default check ratio' do
          expect(TestDataV2::FlagBuilderV2::FlagMigrationSettingsBuilder.new.check_ratio(1).build).to be_nil
        end

        it 'includes a sampling ratio other than 1' do
          td = TestDataV2.data_source
          expect(td.flag('myflag').sampling_ratio(10).build(1)[:samplingRatio]).to eq(10)
          expect(td.flag('myflag').sampling_ratio(1).build(1)).not_to include(:samplingRatio)
        end

        it 'includes exclude from summaries when set' do
          td = TestDataV2.data_source
          expect(td.flag('myflag').exclude_from_summaries(true).build(1)[:excludeFromSummaries]).to be true
          expect(td.flag('myflag').exclude_from_summaries(false).build(1)).not_to include(:excludeFromSummaries)
        end

        it 'copies the settings when the builder is copied' do
          td = TestDataV2.data_source
          td.update(td.flag('myflag').sampling_ratio(10).exclude_from_summaries(true))
          flag = td.flag('myflag').build(1)
          expect(flag[:samplingRatio]).to eq(10)
          expect(flag[:excludeFromSummaries]).to be true
        end
      end

      describe 'TestDataSourceV2' do
        it 'includes both flags and segments in fetch' do
          td = TestDataV2.data_source
          td.update(td.flag('myflag').variation_for_all(true))
          td.use_preconfigured_segment({ key: 'mysegment', included: ['user1'] })

          source = LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2.new(td)
          result = source.fetch(nil)

          expect(result.success?).to be true
          basis = result.value
          change_set = basis.change_set

          # Verify the changeset contains both flags and segments
          expect(change_set.changes.length).to eq(2)

          flag_change = change_set.changes.detect { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG }
          segment_change = change_set.changes.detect { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT }

          expect(flag_change).not_to be_nil
          expect(flag_change.key).to eq(:myflag)

          expect(segment_change).not_to be_nil
          expect(segment_change.key).to eq(:mysegment)
        end

        it 'propagates segment updates' do
          td = TestDataV2.data_source
          source = LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2.new(td)

          updates = []
          sync_thread = Thread.new do
            source.sync(nil) do |update|
              updates << update
              # Stop after receiving 2 updates (initial + one segment update)
              break if updates.length >= 2
            end
          end

          # Wait for initial sync
          sleep 0.1

          # Add a segment
          td.use_preconfigured_segment({ key: 'testsegment', included: ['user1'] })

          # Wait for the update to propagate
          sync_thread.join(1)
          source.stop

          expect(updates.length).to eq(2)
          expect(updates[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
          expect(updates[1].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)

          # Check that the second update contains the segment
          segment_change = updates[1].change_set.changes.detect { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT }
          expect(segment_change).not_to be_nil
          expect(segment_change.key).to eq(:testsegment)
        end
      end
    end
  end
end

