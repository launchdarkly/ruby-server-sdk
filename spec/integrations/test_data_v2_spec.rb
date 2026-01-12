require "ldclient-rb/integrations/test_data_v2"
require "ldclient-rb/impl/integrations/test_data/test_data_source_v2"
require "spec_helper"

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
        td.update(td.flag('my-flag').variation_for_all(true))
        init_data = td.make_init_data
        expect(init_data[:flags].keys).to include('my-flag')
        expect(init_data[:flags]['my-flag'][:key]).to eq('my-flag')
      end

      it 'stores preconfigured segments' do
        td = TestDataV2.data_source
        td.use_preconfigured_segment({ key: 'my-segment', version: 100, included: ['user1'] })
        init_data = td.make_init_data
        expect(init_data[:segments].keys).to include('my-segment')
        expect(init_data[:segments]['my-segment'][:key]).to eq('my-segment')
        expect(init_data[:segments]['my-segment'][:version]).to eq(1)
        expect(init_data[:segments]['my-segment'][:included]).to eq(['user1'])
      end

      it 'increments segment version on update' do
        td = TestDataV2.data_source
        td.use_preconfigured_segment({ key: 'my-segment', version: 100 })
        td.use_preconfigured_segment({ key: 'my-segment', included: ['user2'] })
        init_data = td.make_init_data
        expect(init_data[:segments]['my-segment'][:version]).to eq(2)
        expect(init_data[:segments]['my-segment'][:included]).to eq(['user2'])
      end

      describe 'TestDataSourceV2' do
        it 'includes both flags and segments in fetch' do
          td = TestDataV2.data_source
          td.update(td.flag('my-flag').variation_for_all(true))
          td.use_preconfigured_segment({ key: 'my-segment', included: ['user1'] })

          source = LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2.new(td)
          result = source.fetch(nil)

          expect(result.success?).to be true
          basis = result.value
          change_set = basis.change_set

          # Verify the changeset contains both flags and segments
          expect(change_set.changes.length).to eq(2)

          flag_change = change_set.changes.find { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG }
          segment_change = change_set.changes.find { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT }

          expect(flag_change).not_to be_nil
          expect(flag_change.key).to eq('my-flag')

          expect(segment_change).not_to be_nil
          expect(segment_change.key).to eq('my-segment')
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
          td.use_preconfigured_segment({ key: 'test-segment', included: ['user1'] })

          # Wait for the update to propagate
          sync_thread.join(1)
          source.stop

          expect(updates.length).to eq(2)
          expect(updates[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)
          expect(updates[1].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::VALID)

          # Check that the second update contains the segment
          segment_change = updates[1].change_set.changes.find { |c| c.kind == LaunchDarkly::Interfaces::DataSystem::ObjectKind::SEGMENT }
          expect(segment_change).not_to be_nil
          expect(segment_change.key).to eq('test-segment')
        end
      end
    end
  end
end

