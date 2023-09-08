require 'ldclient-rb/interfaces'
require 'ldclient-rb/impl/migrations/migrator'

require "mock_components"
require "model_builders"

module LaunchDarkly
  module Impl
    module Migrations
      describe Migrator do
        subject { Migrator }
        let(:data_source) {
          td = LaunchDarkly::Integrations::TestData.data_source

          [
            LaunchDarkly::Interfaces::Migrations::STAGE_OFF,
            LaunchDarkly::Interfaces::Migrations::STAGE_DUALWRITE,
            LaunchDarkly::Interfaces::Migrations::STAGE_SHADOW,
            LaunchDarkly::Interfaces::Migrations::STAGE_LIVE,
            LaunchDarkly::Interfaces::Migrations::STAGE_RAMPDOWN,
            LaunchDarkly::Interfaces::Migrations::STAGE_COMPLETE,
          ].each do |stage|
              td.update(td.flag(stage.to_s).variations(stage.to_s).variation_for_all(0))
          end

          td
        }

        def default_builder(client)
          builder = MigratorBuilder.new(client)
          builder.track_latency(false)
          builder.track_errors(false)

          builder.read(->(_) {}, ->(_) {})
          builder.write(->(_) {}, ->(_) {})

          builder
        end

        describe "both operations" do
          describe "pass payload through" do
            [
              LaunchDarkly::Interfaces::Migrations::OP_READ,
              LaunchDarkly::Interfaces::Migrations::OP_WRITE,
            ].each do |op|
              it "for #{op}" do
                with_client(test_config(data_source: data_source)) do |client|
                  builder = default_builder(client)

                  payload_old = nil
                  payload_new = nil

                  old_proc = Proc.new { |payload|
                    payload_old = payload
                    OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, nil)
                  }

                  new_proc = Proc.new { |payload|
                    payload_new = payload
                    OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, nil)
                  }

                  builder.read(old_proc, new_proc)
                  builder.write(old_proc, new_proc)

                  migrator = builder.build

                  if op == LaunchDarkly::Interfaces::Migrations::OP_READ
                    migrator.read(LaunchDarkly::Interfaces::Migrations::STAGE_LIVE.to_s, basic_context, LaunchDarkly::Interfaces::Migrations::STAGE_OFF, "example payload")
                  else
                    migrator.write(LaunchDarkly::Interfaces::Migrations::STAGE_LIVE.to_s, basic_context, LaunchDarkly::Interfaces::Migrations::STAGE_OFF, "example payload")
                  end

                  expect(payload_old).to eq("example payload")
                  expect(payload_new).to eq("example payload")
                end
              end
            end
          end

          describe "track invoked" do
            # TODO(uc2-migrations): Fill out once op event is emitted
          end

          describe "track consistency" do
            # TODO(uc2-migrations): Fill out once op event is emitted
          end

          describe "track errors" do
            # TODO(uc2-migrations): Fill out once op event is emitted
          end
        end

        describe "read operations" do
          describe "correct origin is run" do
            [
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_OFF, old: true, new: false },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_DUALWRITE, old: true, new: false },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_SHADOW, old: true, new: true },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_LIVE, old: true, new: true },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_RAMPDOWN, old: false, new: true },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_COMPLETE, old: false, new: true },
            ].each do |params|
              it "for #{params[:stage]} stage" do
                with_client(test_config(data_source: data_source)) do |client|
                  builder = default_builder(client)

                  called_old = false
                  called_new = false

                  builder.read(
                    Proc.new { |_|
                      called_old = true
                      OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, nil)
                    },
                    Proc.new { |_|
                      called_new = true
                      OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, nil)
                    }
                  )

                  migrator = builder.build
                  migrator.read(params[:stage].to_s, basic_context, LaunchDarkly::Interfaces::Migrations::STAGE_OFF)

                  expect(called_old).to eq(params[:old])
                  expect(called_new).to eq(params[:new])
                end
              end
            end
          end

          describe "support execution order" do
            it "parallel" do
              with_client(test_config(data_source: data_source)) do |client|
                builder = default_builder(client)

                builder.read(
                  Proc.new { |_|
                    sleep(0.5)
                    OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, nil)
                  },
                  Proc.new { |_|
                    sleep(0.5)
                    OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, nil)
                  }
                )

                migrator = builder.build

                start = Time.now
                migrator.read(LaunchDarkly::Interfaces::Migrations::STAGE_SHADOW.to_s, basic_context, LaunchDarkly::Interfaces::Migrations::STAGE_OFF)
                duration = Time.now - start

                expect(duration).to be < 1
              end
            end

            it "serial" do
              with_client(test_config(data_source: data_source)) do |client|
                builder = default_builder(client)
                builder.read_execution_order(LaunchDarkly::Impl::Migrations::MigratorBuilder::EXECUTION_SERIAL)

                builder.read(
                  Proc.new { |_|
                    sleep(0.5)
                    OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, nil)
                  },
                  Proc.new { |_|
                    sleep(0.5)
                    OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, nil)
                  }
                )

                migrator = builder.build

                start = Time.now
                migrator.read(LaunchDarkly::Interfaces::Migrations::STAGE_SHADOW.to_s, basic_context, LaunchDarkly::Interfaces::Migrations::STAGE_OFF)
                duration = Time.now - start

                expect(duration).to be >= 1
              end
            end

            it "random" do
              with_client(test_config(data_source: data_source)) do |client|
                builder = default_builder(client)
                builder.read_execution_order(LaunchDarkly::Impl::Migrations::MigratorBuilder::EXECUTION_RANDOM)

                builder.read(
                  Proc.new { |_|
                    sleep(0.5)
                    OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, nil)
                  },
                  Proc.new { |_|
                    sleep(0.5)
                    OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, nil)
                  }
                )

                migrator = builder.build

                start = Time.now
                migrator.read(LaunchDarkly::Interfaces::Migrations::STAGE_SHADOW.to_s, basic_context, LaunchDarkly::Interfaces::Migrations::STAGE_OFF)
                duration = Time.now - start

                # Since it is random, we don't know which decision it would make, so the best we can do is make sure it
                # wasn't run in parallel.
                expect(duration).to be >= 1
              end
            end
          end

          it "tracks consistency results" do
            # TODO(uc2-migrations): Fill out once op event is emitted
          end
        end

        describe "write operations" do
          describe "correct origin is run" do
            [
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_OFF, old: true, new: false },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_DUALWRITE, old: true, new: true },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_SHADOW, old: true, new: true },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_LIVE, old: true, new: true },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_RAMPDOWN, old: true, new: true },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_COMPLETE, old: false, new: true },
            ].each do |params|
              it "for #{params[:stage]} stage" do
                with_client(test_config(data_source: data_source)) do |client|
                  builder = default_builder(client)

                  called_old = false
                  called_new = false

                  builder.write(
                    Proc.new { |_|
                      called_old = true
                      OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, nil)
                    },
                    Proc.new { |_|
                      called_new = true
                      OperationResult.success(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, nil)
                    }
                  )

                  migrator = builder.build
                  migrator.write(params[:stage].to_s, basic_context, LaunchDarkly::Interfaces::Migrations::STAGE_OFF)

                  expect(called_old).to eq(params[:old])
                  expect(called_new).to eq(params[:new])
                end
              end
            end
          end

          describe "stop if authoritative write fails" do
            [
              # LaunchDarkly::Interfaces::Migrations::STAGE_OFF doesn't run both so we can ignore it.
              #
              # Old is authoritative, so new shouldn't be called
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_DUALWRITE, old: true, new: false },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_SHADOW, old: true, new: false },

              # New is authoritative, so old shouldn't be called
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_LIVE, old: false, new: true },
              { stage: LaunchDarkly::Interfaces::Migrations::STAGE_RAMPDOWN, old: false, new: true },

              # LaunchDarkly::Interfaces::Migrations::STAGE_COMPLETE doesn't run both so we can ignore it.
            ].each do |params|
              it "for #{params[:stage]} stage" do
                with_client(test_config(data_source: data_source)) do |client|
                  builder = default_builder(client)

                  called_old = false
                  called_new = false

                  builder.write(
                    Proc.new { |_|
                      called_old = true
                      OperationResult.fail(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, "failed old")
                    },
                    Proc.new { |_|
                      called_new = true
                      OperationResult.fail(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, "failed new")
                    }
                  )

                  migrator = builder.build
                  migrator.write(params[:stage].to_s, basic_context, LaunchDarkly::Interfaces::Migrations::STAGE_OFF)

                  expect(called_old).to eq(params[:old])
                  expect(called_new).to eq(params[:new])
                end
              end
            end
          end
        end
      end
    end
  end
end
