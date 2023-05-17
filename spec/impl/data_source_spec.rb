require "spec_helper"

module LaunchDarkly
  module Impl
    describe DataSource::UpdateSink do
      subject { DataSource::UpdateSink }
      let(:store) { InMemoryFeatureStore.new }
      let(:executor) { SynchronousExecutor.new }
      let(:status_broadcaster) { LaunchDarkly::Impl::Broadcaster.new(executor, $null_log) }
      let(:flag_change_broadcaster) { LaunchDarkly::Impl::Broadcaster.new(executor, $null_log) }
      let(:sink) { subject.new(store, status_broadcaster, flag_change_broadcaster) }

      it "defaults to initializing" do
        expect(sink.current_status.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING)
        expect(sink.current_status.last_error).to be_nil
      end

      it "setting status to interrupted while initializing maintains initializing state" do
        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, nil)
        expect(sink.current_status.state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING)
        expect(sink.current_status.last_error).to be_nil
      end

      it "listener is triggered only for state changes" do
        listener = ListenerSpy.new
        status_broadcaster.add_listener(listener)

        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
        expect(listener.statuses.count).to eq(1)

        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, nil)
        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED, nil)
        expect(listener.statuses.count).to eq(2)
      end

      it "all listeners are called for a single change" do
        listener1 = ListenerSpy.new
        status_broadcaster.add_listener(listener1)

        listener2 = ListenerSpy.new
        status_broadcaster.add_listener(listener2)

        sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)
        expect(listener1.statuses.count).to eq(1)
        expect(listener2.statuses.count).to eq(1)
      end

      describe "simple flag change listener" do
        let(:all_data) {
          {
            LaunchDarkly::FEATURES => {
              flag1: LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag1', version: 1 }),
              flag2: LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag2', version: 1 }),
              flag3: LaunchDarkly::Impl::Model::FeatureFlag.new(
                {
                  key: 'flag3',
                  version: 1,
                  variation: 0,
                  rules: [
                    {
                      clauses: [
                        {
                          contextKind: 'user',
                          attribute: 'segmentMatch',
                          op: 'segmentMatch',
                          values: [
                            'segment2',
                          ],
                          negate: false,
                        },
                      ],
                    },
                  ],
                }
              ),
            },
            LaunchDarkly::SEGMENTS => {
              segment1: LaunchDarkly::Impl::Model::Segment.new({ key: 'segment1', version: 1 }),
              segment2: LaunchDarkly::Impl::Model::Segment.new({ key: 'segment2', version: 1 }),
            },
          }
        }

        it "is called once per flag changed during init" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          updated_data = {
            LaunchDarkly::FEATURES => {
              flag1: LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag1', version: 2 }),
              flag4: LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag4', version: 1 }),
            },
          }

          sink.init(updated_data)

          expect(listener.statuses.count).to eq(4)
          expect(listener.statuses[0].key).to eq('flag1') # Version update
          expect(listener.statuses[1].key).to eq('flag2') # Deleted
          expect(listener.statuses[2].key).to eq('flag3') # Deleted
          expect(listener.statuses[3].key).to eq('flag4') # Newly created
        end

        it "is called if flag changes through upsert" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          sink.upsert(LaunchDarkly::FEATURES, LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag1', version: 2 }))
          # TODO(sc-197908): Once the store starts returning a success status on upsert, the flag change notification
          # can start ignoring duplicate requests like this.
          # sink.upsert(LaunchDarkly::FEATURES, LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag1', version: 2 }))

          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].key).to eq('flag1')
        end

        it "is called if flag is deleted" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          sink.delete(LaunchDarkly::FEATURES, "flag1", 2)
          # TODO(sc-197908): Once the store starts returning a success status on delete, the flag change notification
          # can start ignoring duplicate requests like this.
          # sink.delete(LaunchDarkly::FEATURES, :flag1, 2)

          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].key).to eq("flag1")
        end

        it "is called if the segment is updated" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          sink.upsert(LaunchDarkly::SEGMENTS, LaunchDarkly::Impl::Model::Segment.new({ key: 'segment2', version: 2 }))
          # TODO(sc-197908): Once the store starts returning a success status on upsert, the flag change notification
          # can start ignoring duplicate requests like this.
          # sink.upsert(LaunchDarkly::Impl::Model::Segment.new({ key: 'segment2', version: 2 }))

          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].key).to eq('flag3')
        end
      end

      describe "prerequisite flag change listener" do
        let(:all_data) {
          {
            LaunchDarkly::FEATURES => {
              flag1: LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag1', version: 1, prerequisites: [{key: 'flag2', variation: 0}] }),
              flag2: LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag2', version: 1,
prerequisites: [{key: 'flag3', variation: 0}, {key: 'flag4', variation: 0}, {key: 'flag6', variation: 0}] }),
              flag3: LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag3', version: 1 }),
              flag4: LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag4', version: 1 }),
              flag5: LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag5', version: 1 }),
              flag6: LaunchDarkly::Impl::Model::FeatureFlag.new(
                {
                  key: 'flag6',
                  version: 1,
                  variation: 0,
                  rules: [
                    {
                      clauses: [
                        {
                          contextKind: 'user',
                          attribute: 'segmentMatch',
                          op: 'segmentMatch',
                          values: [
                            'segment2',
                          ],
                          negate: false,
                        },
                      ],
                    },
                  ],
                }
              ),
            },
            LaunchDarkly::SEGMENTS => {
              segment1: LaunchDarkly::Impl::Model::Segment.new({ key: 'segment1', version: 1 }),
              segment2: LaunchDarkly::Impl::Model::Segment.new(
                {
                  key: 'segment2',
                  version: 1,
                  rules: [
                    {
                      clauses: [
                        {
                          contextKind: 'user',
                          attribute: 'segmentMatch',
                          op: 'segmentMatch',
                          values: [
                            'segment1',
                          ],
                          negate: false,
                        },
                      ],
                      rolloutContextKind: 'user',
                    },
                  ],

                }
              ),
            },
          }
        }

        it "triggers for entire dependency stack if top of chain is changed" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          sink.upsert(LaunchDarkly::FEATURES, LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag4', version: 2 }))
          expect(listener.statuses.count).to eq(3)
          expect(listener.statuses[0].key).to eq('flag4')
          expect(listener.statuses[1].key).to eq('flag2')
          expect(listener.statuses[2].key).to eq('flag1')
        end

        it "triggers when new pre-requisites are added" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          sink.upsert(LaunchDarkly::FEATURES, LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag3', version: 2, prerequisities: [{key: 'flag4', variation: 0}] }))
          expect(listener.statuses.count).to eq(3)
          expect(listener.statuses[0].key).to eq('flag3')
          expect(listener.statuses[1].key).to eq('flag2')
          expect(listener.statuses[2].key).to eq('flag1')
        end

        it "triggers when new pre-requisites are removed" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          sink.upsert(LaunchDarkly::FEATURES, LaunchDarkly::Impl::Model::FeatureFlag.new({ key: 'flag2', version: 2, prerequisities: [{key: 'flag3', variation: 0}] }))
          expect(listener.statuses.count).to eq(2)
          expect(listener.statuses[0].key).to eq('flag2')
          expect(listener.statuses[1].key).to eq('flag1')
        end

        it "triggers for entire dependency stack if top of chain is deleted" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          sink.delete(LaunchDarkly::FEATURES, "flag4", 2)
          expect(listener.statuses.count).to eq(3)
          expect(listener.statuses[0].key).to eq('flag4')
          expect(listener.statuses[1].key).to eq('flag2')
          expect(listener.statuses[2].key).to eq('flag1')
        end

        it "triggers if dependent segment is modified" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          sink.upsert(LaunchDarkly::SEGMENTS, LaunchDarkly::Impl::Model::Segment.new({ key: 'segment1', version: 2 }))
          # TODO(sc-197908): Once the store starts returning a success status on upsert, the flag change notification
          # can start ignoring duplicate requests like this.
          # sink.upsert(LaunchDarkly::SEGMENTS, LaunchDarkly::Impl::Model::Segment.new({ key: 'segment1', version: 2 }))

          expect(listener.statuses.count).to eq(3)
          expect(listener.statuses[0].key).to eq('flag6')
          expect(listener.statuses[1].key).to eq('flag2')
          expect(listener.statuses[2].key).to eq('flag1')
        end

        it "triggers if dependent segment rule is removed" do
          sink.init(all_data)

          listener = ListenerSpy.new
          flag_change_broadcaster.add_listener(listener)

          sink.delete(LaunchDarkly::SEGMENTS, 'segment2', 2)
          # TODO(sc-197908): Once the store starts returning a success status on upsert, the flag change notification
          # can start ignoring duplicate requests like this.
          # sink.delete(LaunchDarkly::SEGMENTS, 'segment2', 2)

          expect(listener.statuses.count).to eq(3)
          expect(listener.statuses[0].key).to eq('flag6')
          expect(listener.statuses[1].key).to eq('flag2')
          expect(listener.statuses[2].key).to eq('flag1')
        end
      end

      describe "listeners are triggered for store errors" do
        def confirm_store_error(error_type)
          # Make it valid first so the error changes from initializing
          sink.update_status(LaunchDarkly::Interfaces::DataSource::Status::VALID, nil)

          listener = ListenerSpy.new
          status_broadcaster.add_listener(listener)

          allow(store).to receive(:init).and_raise(StandardError.new("init error"))
          allow(store).to receive(:upsert).and_raise(StandardError.new("upsert error"))
          allow(store).to receive(:delete).and_raise(StandardError.new("delete error"))

          begin
            yield
          rescue
            # ignored
          end

          expect(listener.statuses.count).to eq(1)
          expect(listener.statuses[0].state).to eq(LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED)
          expect(listener.statuses[0].last_error.kind).to eq(LaunchDarkly::Interfaces::DataSource::ErrorInfo::STORE_ERROR)
          expect(listener.statuses[0].last_error.message).to eq("#{error_type} error")
        end

        it "when calling init" do
          confirm_store_error("init") { sink.init({}) }
        end

        it "when calling upsert" do
          confirm_store_error("upsert") { sink.upsert("flag", nil) }
        end

        it "when calling delete" do
          confirm_store_error("delete") { sink.delete("flag", "flag-key", 1) }
        end
      end
    end
  end
end
