require 'ldclient-rb/interfaces'
require 'ldclient-rb/impl/migrations/migrator'

require "events_test_util"
require "mock_components"
require "model_builders"

module LaunchDarkly
  module Impl
    module Migrations
      describe Migrator do
        subject { Migrator }
        let(:default_config) { LaunchDarkly::Config.new({ diagnostic_opt_out: true, logger: $null_log }) }
        let(:data_source) {
          td = LaunchDarkly::Integrations::TestData.data_source

          [
            LaunchDarkly::Migrations::STAGE_OFF,
            LaunchDarkly::Migrations::STAGE_DUALWRITE,
            LaunchDarkly::Migrations::STAGE_SHADOW,
            LaunchDarkly::Migrations::STAGE_LIVE,
            LaunchDarkly::Migrations::STAGE_RAMPDOWN,
            LaunchDarkly::Migrations::STAGE_COMPLETE,
          ].each do |stage|
              td.update(td.flag(stage.to_s).variations(stage.to_s).variation_for_all(0))
          end

          td
        }

        def default_builder(client)
          builder = LaunchDarkly::Migrations::MigratorBuilder.new(client)
          builder.track_latency(false)
          builder.track_errors(false)

          builder.read(->(_) {}, ->(_) {})
          builder.write(->(_) {}, ->(_) {})

          builder
        end

        describe "both operations" do

          describe "pass payload through" do
            [
              LaunchDarkly::Migrations::OP_READ,
              LaunchDarkly::Migrations::OP_WRITE,
            ].each do |op|
              it "for #{op}" do
                with_client(test_config(data_source: data_source)) do |client|
                  builder = default_builder(client)

                  payload_old = nil
                  payload_new = nil

                  old_callable = ->(payload) {
                    payload_old = payload
                    LaunchDarkly::Result.success(nil)
                  }

                  new_callable = ->(payload) {
                    payload_new = payload
                    LaunchDarkly::Result.success(nil)
                  }

                  builder.read(old_callable, new_callable)
                  builder.write(old_callable, new_callable)

                  migrator = builder.build

                  if op == LaunchDarkly::Migrations::OP_READ
                    migrator.read(LaunchDarkly::Migrations::STAGE_LIVE.to_s, basic_context, LaunchDarkly::Migrations::STAGE_OFF, "example payload")
                  else
                    migrator.write(LaunchDarkly::Migrations::STAGE_LIVE.to_s, basic_context, LaunchDarkly::Migrations::STAGE_OFF, "example payload")
                  end

                  expect(payload_old).to eq("example payload")
                  expect(payload_new).to eq("example payload")
                end
              end
            end
          end

          describe "track invoked" do
            [
              {label: "read off", stage: LaunchDarkly::Migrations::STAGE_OFF, op: LaunchDarkly::Migrations::OP_READ, expected: ["old"]},
              {label: "read dual write", stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, op: LaunchDarkly::Migrations::OP_READ, expected: ["old"]},
              {label: "read shadow", stage: LaunchDarkly::Migrations::STAGE_SHADOW, op: LaunchDarkly::Migrations::OP_READ, expected: %w[old new]},
              {label: "read live", stage: LaunchDarkly::Migrations::STAGE_LIVE, op: LaunchDarkly::Migrations::OP_READ, expected: %w[old new]},
              {label: "read ramp down", stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, op: LaunchDarkly::Migrations::OP_READ, expected: ["new"]},
              {label: "read complete", stage: LaunchDarkly::Migrations::STAGE_COMPLETE, op: LaunchDarkly::Migrations::OP_READ, expected: ["new"]},

              {label: "write off", stage: LaunchDarkly::Migrations::STAGE_OFF, op: LaunchDarkly::Migrations::OP_WRITE, expected: ["old"]},
              {label: "write dual write", stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, op: LaunchDarkly::Migrations::OP_WRITE, expected: %w[old new]},
              {label: "write shadow", stage: LaunchDarkly::Migrations::STAGE_SHADOW, op: LaunchDarkly::Migrations::OP_WRITE, expected: %w[old new]},
              {label: "write live", stage: LaunchDarkly::Migrations::STAGE_LIVE, op: LaunchDarkly::Migrations::OP_WRITE, expected: %w[old new]},
              {label: "write ramp down", stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, op: LaunchDarkly::Migrations::OP_WRITE, expected: %w[old new]},
              {label: "write complete", stage: LaunchDarkly::Migrations::STAGE_COMPLETE, op: LaunchDarkly::Migrations::OP_WRITE, expected: ["new"]},
            ].each do |test_param|
              it "for #{test_param[:label]}" do
                with_client(test_config(data_source: data_source)) do |client|
                  with_processor_and_sender(default_config, 0) do |ep, sender|
                    override_client_event_processor(client, ep)

                    builder = default_builder(client)
                    old_callable = ->(_) { LaunchDarkly::Result.success(nil) }
                    new_callable = ->(_) { LaunchDarkly::Result.success(nil) }

                    builder.read(old_callable, new_callable)
                    builder.write(old_callable, new_callable)
                    migrator = builder.build

                    if test_param[:op] == LaunchDarkly::Migrations::OP_READ
                      migrator.read(test_param[:stage], basic_context, LaunchDarkly::Migrations::STAGE_OFF, "example payload")
                    else
                      migrator.write(test_param[:stage], basic_context, LaunchDarkly::Migrations::STAGE_OFF, "example payload")
                    end

                    ep.flush
                    ep.wait_until_inactive
                    events = sender.analytics_payloads.pop

                    expect(events.size).to be(3) # Index, migration op, and summary

                    op_event = events[1]
                    invocations = op_event[:measurements][0]

                    expect(invocations[:key]).to eq("invoked")
                    test_param[:expected].each { |ev| expect(invocations[:values]).to include({ev.to_sym => true}) }
                  end
                end
              end
            end
          end

          describe "track latency" do
            [
              {label: "read off", stage: LaunchDarkly::Migrations::STAGE_OFF, op: LaunchDarkly::Migrations::OP_READ, expected: [:old]},
              {label: "read dual write", stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, op: LaunchDarkly::Migrations::OP_READ, expected: [:old]},
              {label: "read shadow", stage: LaunchDarkly::Migrations::STAGE_SHADOW, op: LaunchDarkly::Migrations::OP_READ, expected: [:old, :new]},
              {label: "read live", stage: LaunchDarkly::Migrations::STAGE_LIVE, op: LaunchDarkly::Migrations::OP_READ, expected: [:old, :new]},
              {label: "read ramp down", stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, op: LaunchDarkly::Migrations::OP_READ, expected: [:new]},
              {label: "read complete", stage: LaunchDarkly::Migrations::STAGE_COMPLETE, op: LaunchDarkly::Migrations::OP_READ, expected: [:new]},

              {label: "write off", stage: LaunchDarkly::Migrations::STAGE_OFF, op: LaunchDarkly::Migrations::OP_WRITE, expected: [:old]},
              {label: "write dual write", stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, op: LaunchDarkly::Migrations::OP_WRITE, expected: [:old, :new]},
              {label: "write shadow", stage: LaunchDarkly::Migrations::STAGE_SHADOW, op: LaunchDarkly::Migrations::OP_WRITE, expected: [:old, :new]},
              {label: "write live", stage: LaunchDarkly::Migrations::STAGE_LIVE, op: LaunchDarkly::Migrations::OP_WRITE, expected: [:old, :new]},
              {label: "write ramp down", stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, op: LaunchDarkly::Migrations::OP_WRITE, expected: [:old, :new]},
              {label: "write complete", stage: LaunchDarkly::Migrations::STAGE_COMPLETE, op: LaunchDarkly::Migrations::OP_WRITE, expected: [:new]},
            ].each do |test_param|
              it "for #{test_param[:label]}" do
                with_client(test_config(data_source: data_source)) do |client|
                  with_processor_and_sender(default_config, 0) do |ep, sender|
                    override_client_event_processor(client, ep)

                    builder = default_builder(client)
                    builder.track_latency(true)
                    old_callable = ->(_) { sleep(0.1) && LaunchDarkly::Result.success(nil) }
                    new_callable = ->(_) { sleep(0.1) && LaunchDarkly::Result.success(nil) }

                    builder.read(old_callable, new_callable)
                    builder.write(old_callable, new_callable)
                    migrator = builder.build

                    if test_param[:op] == LaunchDarkly::Migrations::OP_READ
                      migrator.read(test_param[:stage], basic_context, LaunchDarkly::Migrations::STAGE_OFF, "example payload")
                    else
                      migrator.write(test_param[:stage], basic_context, LaunchDarkly::Migrations::STAGE_OFF, "example payload")
                    end

                    ep.flush
                    ep.wait_until_inactive
                    events = sender.analytics_payloads.pop

                    expect(events.size).to be(3) # Index, migration op, and summary

                    op_event = events[1]
                    latencies = op_event[:measurements][1] # First measurement is invoked

                    expect(latencies[:key]).to eq("latency_ms")
                    test_param[:expected].each { |ev| expect(latencies[:values][ev]).to be >= 0.1 }
                  end
                end
              end
            end
          end
        end

        describe "read operations" do
          describe "correct origin is run" do
            [
              { stage: LaunchDarkly::Migrations::STAGE_OFF, old: true, new: false },
              { stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, old: true, new: false },
              { stage: LaunchDarkly::Migrations::STAGE_SHADOW, old: true, new: true },
              { stage: LaunchDarkly::Migrations::STAGE_LIVE, old: true, new: true },
              { stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, old: false, new: true },
              { stage: LaunchDarkly::Migrations::STAGE_COMPLETE, old: false, new: true },
            ].each do |params|
              it "for #{params[:stage]} stage" do
                with_client(test_config(data_source: data_source)) do |client|
                  builder = default_builder(client)

                  called_old = false
                  called_new = false

                  builder.read(
                    ->(_) {
                      called_old = true
                      LaunchDarkly::Result.success(nil)
                    },
                    ->(_) {
                      called_new = true
                      LaunchDarkly::Result.success(nil)
                    }
                  )

                  migrator = builder.build
                  migrator.read(params[:stage].to_s, basic_context, LaunchDarkly::Migrations::STAGE_OFF)

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
                  ->(_) {
                    sleep(0.5)
                    LaunchDarkly::Result.success(nil)
                  },
                  ->(_) {
                    sleep(0.5)
                    LaunchDarkly::Result.success(nil)
                  }
                )

                migrator = builder.build

                start = Time.now
                migrator.read(LaunchDarkly::Migrations::STAGE_SHADOW.to_s, basic_context, LaunchDarkly::Migrations::STAGE_OFF)
                duration = Time.now - start

                expect(duration).to be < 1
              end
            end

            it "serial" do
              with_client(test_config(data_source: data_source)) do |client|
                builder = default_builder(client)
                builder.read_execution_order(LaunchDarkly::Migrations::MigratorBuilder::EXECUTION_SERIAL)

                builder.read(
                  ->(_) {
                    sleep(0.5)
                    LaunchDarkly::Result.success(nil)
                  },
                  ->(_) {
                    sleep(0.5)
                    LaunchDarkly::Result.success(nil)
                  }
                )

                migrator = builder.build

                start = Time.now
                migrator.read(LaunchDarkly::Migrations::STAGE_SHADOW.to_s, basic_context, LaunchDarkly::Migrations::STAGE_OFF)
                duration = Time.now - start

                expect(duration).to be >= 1
              end
            end

            it "random" do
              with_client(test_config(data_source: data_source)) do |client|
                builder = default_builder(client)
                builder.read_execution_order(LaunchDarkly::Migrations::MigratorBuilder::EXECUTION_RANDOM)

                builder.read(
                  ->(_) {
                    sleep(0.5)
                    LaunchDarkly::Result.success(nil)
                  },
                  ->(_) {
                    sleep(0.5)
                    LaunchDarkly::Result.success(nil)
                  }
                )

                migrator = builder.build

                start = Time.now
                migrator.read(LaunchDarkly::Migrations::STAGE_SHADOW.to_s, basic_context, LaunchDarkly::Migrations::STAGE_OFF)
                duration = Time.now - start

                # Since it is random, we don't know which decision it would make, so the best we can do is make sure it
                # wasn't run in parallel.
                expect(duration).to be >= 1
              end
            end
          end

          describe "tracks consistency results" do
            [
              {label: "shadow when same", stage: LaunchDarkly::Migrations::STAGE_SHADOW, old_return: "same", new_return: "same", expected: true},
              {label: "shadow when different", stage: LaunchDarkly::Migrations::STAGE_SHADOW, old_return: "same", new_return: "different", expected: false},

              {label: "live when same", stage: LaunchDarkly::Migrations::STAGE_LIVE, old_return: "same", new_return: "same", expected: true},
              {label: "live when different", stage: LaunchDarkly::Migrations::STAGE_LIVE, old_return: "same", new_return: "different", expected: false},
            ].each do |test_param|
              it "for #{test_param[:label]}" do
                with_client(test_config(data_source: data_source)) do |client|
                  with_processor_and_sender(default_config, 0) do |ep, sender|
                    override_client_event_processor(client, ep)

                    builder = default_builder(client)
                    old_callable = ->(_) { LaunchDarkly::Result.success(test_param[:old_return]) }
                    new_callable = ->(_) { LaunchDarkly::Result.success(test_param[:new_return]) }
                    compare_callable = ->(lhs, rhs) { lhs.value == rhs.value }

                    builder.read(old_callable, new_callable, compare_callable)
                    builder.write(old_callable, new_callable)
                    migrator = builder.build

                    migrator.read(test_param[:stage], basic_context, LaunchDarkly::Migrations::STAGE_OFF)

                    ep.flush
                    ep.wait_until_inactive
                    events = sender.analytics_payloads.pop

                    expect(events.size).to be(3) # Index, migration op, and summary

                    op_event = events[1]
                    latencies = op_event[:measurements][1] # First measurement is invoked

                    expect(latencies[:key]).to eq("consistent")
                    expect(latencies[:value]).to eq(test_param[:expected])
                  end
                end
              end
            end
          end

          describe "track errors" do
            let(:default_config) { LaunchDarkly::Config.new({ diagnostic_opt_out: true, logger: $null_log }) }

            [
              {label: "off", stage: LaunchDarkly::Migrations::STAGE_OFF, expected: ["old"]},
              {label: "dual write", stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, expected: ["old"]},
              {label: "shadow", stage: LaunchDarkly::Migrations::STAGE_SHADOW, expected: %w[old new]},
              {label: "live", stage: LaunchDarkly::Migrations::STAGE_LIVE, expected: %w[old new]},
              {label: "ramp down", stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, expected: ["new"]},
              {label: "complete", stage: LaunchDarkly::Migrations::STAGE_COMPLETE, expected: ["new"]},
            ].each do |test_param|
              it "for #{test_param[:label]}" do
                with_client(test_config(data_source: data_source)) do |client|
                  with_processor_and_sender(default_config, 0) do |ep, sender|
                    override_client_event_processor(client, ep)

                    builder = default_builder(client)
                    builder.track_errors(true)
                    old_callable = ->(_) { LaunchDarkly::Result.fail("old") }
                    new_callable = ->(_) { LaunchDarkly::Result.fail("new") }

                    builder.read(old_callable, new_callable)
                    builder.write(old_callable, new_callable)
                    migrator = builder.build

                    migrator.read(test_param[:stage], basic_context, LaunchDarkly::Migrations::STAGE_OFF)

                    ep.flush
                    ep.wait_until_inactive
                    events = sender.analytics_payloads.pop

                    expect(events.size).to be(3) # Index, migration op, and summary

                    op_event = events[1]
                    errors = op_event[:measurements][1] # First measurement is invoked

                    expect(errors[:key]).to eq("error")
                    test_param[:expected].each { |ev| expect(errors[:values]).to include({ev.to_sym => true}) }
                  end
                end
              end
            end
          end
        end

        describe "write operations" do
          describe "correct origin is run" do
            [
              { stage: LaunchDarkly::Migrations::STAGE_OFF, old: true, new: false },
              { stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, old: true, new: true },
              { stage: LaunchDarkly::Migrations::STAGE_SHADOW, old: true, new: true },
              { stage: LaunchDarkly::Migrations::STAGE_LIVE, old: true, new: true },
              { stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, old: true, new: true },
              { stage: LaunchDarkly::Migrations::STAGE_COMPLETE, old: false, new: true },
            ].each do |params|
              it "for #{params[:stage]}" do
                with_client(test_config(data_source: data_source)) do |client|
                  builder = default_builder(client)

                  called_old = false
                  called_new = false

                  builder.write(
                    ->(_) {
                      called_old = true
                      LaunchDarkly::Result.success(nil)
                    },
                    ->(_) {
                      called_new = true
                      LaunchDarkly::Result.success(nil)
                    }
                  )

                  migrator = builder.build
                  migrator.write(params[:stage].to_s, basic_context, LaunchDarkly::Migrations::STAGE_OFF)

                  expect(called_old).to eq(params[:old])
                  expect(called_new).to eq(params[:new])
                end
              end
            end
          end

          describe "stop if authoritative write fails" do
            [
              # LaunchDarkly::Migrations::STAGE_OFF doesn't run both so we can ignore it.
              #
              # Old is authoritative, so new shouldn't be called
              { stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, old: true, new: false },
              { stage: LaunchDarkly::Migrations::STAGE_SHADOW, old: true, new: false },

              # New is authoritative, so old shouldn't be called
              { stage: LaunchDarkly::Migrations::STAGE_LIVE, old: false, new: true },
              { stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, old: false, new: true },

              # LaunchDarkly::Migrations::STAGE_COMPLETE doesn't run both so we can ignore it.
            ].each do |params|
              it "for #{params[:stage]} stage" do
                with_client(test_config(data_source: data_source)) do |client|
                  builder = default_builder(client)

                  called_old = false
                  called_new = false

                  builder.write(
                    ->(_) {
                      called_old = true
                      LaunchDarkly::Result.fail("failed old")
                    },
                    ->(_) {
                      called_new = true
                      LaunchDarkly::Result.fail("failed new")
                    }
                  )

                  migrator = builder.build
                  migrator.write(params[:stage].to_s, basic_context, LaunchDarkly::Migrations::STAGE_OFF)

                  expect(called_old).to eq(params[:old])
                  expect(called_new).to eq(params[:new])
                end
              end
            end
          end

          describe "track errors" do
            describe "correctly if authoritative fails first" do
              [
                {label: "write off", stage: LaunchDarkly::Migrations::STAGE_OFF, expected: "old"},
                {label: "write dual write", stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, expected: "old"},
                {label: "write shadow", stage: LaunchDarkly::Migrations::STAGE_SHADOW, expected: "old"},
                {label: "write live", stage: LaunchDarkly::Migrations::STAGE_LIVE, expected: "new"},
                {label: "write ramp down", stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, expected: "new"},
                {label: "write complete", stage: LaunchDarkly::Migrations::STAGE_COMPLETE, expected: "new"},
              ].each do |test_param|
                it test_param[:label] do
                  with_client(test_config(data_source: data_source)) do |client|
                    with_processor_and_sender(default_config, 0) do |ep, sender|
                      override_client_event_processor(client, ep)

                      builder = default_builder(client)
                      builder.track_errors(true)
                      old_callable = ->(_) { LaunchDarkly::Result.fail("old") }
                      new_callable = ->(_) { LaunchDarkly::Result.fail("new") }

                      builder.read(old_callable, new_callable)
                      builder.write(old_callable, new_callable)
                      migrator = builder.build

                      migrator.write(test_param[:stage], basic_context, LaunchDarkly::Migrations::STAGE_OFF)

                      ep.flush
                      ep.wait_until_inactive
                      events = sender.analytics_payloads.pop

                      expect(events.size).to be(3) # Index, migration op, and summary

                      op_event = events[1]
                      errors = op_event[:measurements][1] # First measurement is invoked

                      expect(errors[:key]).to eq("error")
                      expect(errors[:values]).to include({test_param[:expected].to_sym => true})
                    end
                  end
                end
              end
            end

            describe "correctly if authoritative does not fail" do
              [
                # OFF and COMPLETE do not run both origins, so there is nothing to test.
                {label: "dual write", stage: LaunchDarkly::Migrations::STAGE_DUALWRITE, old_fail: false, new_fail: true, expected: "new"},
                {label: "shadow", stage: LaunchDarkly::Migrations::STAGE_SHADOW, old_fail: false, new_fail: true, expected: "new"},
                {label: "live", stage: LaunchDarkly::Migrations::STAGE_LIVE, old_fail: true, new_fail: false, expected: "old"},
                {label: "ramp down", stage: LaunchDarkly::Migrations::STAGE_RAMPDOWN, old_fail: true, new_fail: false, expected: "old"},
              ].each do |test_param|
                it "for #{test_param[:label]}" do
                  with_client(test_config(data_source: data_source)) do |client|
                    with_processor_and_sender(default_config, 0) do |ep, sender|
                      override_client_event_processor(client, ep)

                      builder = default_builder(client)
                      builder.track_errors(true)

                      old_callable = ->(_) {
                        if test_param[:old_fail]
                          LaunchDarkly::Result.fail("old")
                        else
                          LaunchDarkly::Result.success(nil)
                        end
                      }
                      new_callable = ->(_) {
                        if test_param[:new_fail]
                          LaunchDarkly::Result.fail("new")
                        else
                          LaunchDarkly::Result.success(nil)
                        end
                      }

                      builder.read(old_callable, new_callable)
                      builder.write(old_callable, new_callable)
                      migrator = builder.build

                      migrator.write(test_param[:stage], basic_context, LaunchDarkly::Migrations::STAGE_OFF)

                      ep.flush
                      ep.wait_until_inactive
                      events = sender.analytics_payloads.pop

                      expect(events.size).to be(3) # Index, migration op, and summary

                      op_event = events[1]
                      errors = op_event[:measurements][1] # First measurement is invoked

                      expect(errors[:key]).to eq("error")
                      expect(errors[:values]).to include({test_param[:expected].to_sym => true})
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
