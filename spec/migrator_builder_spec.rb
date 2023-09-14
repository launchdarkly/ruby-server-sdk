require 'ldclient-rb/interfaces'
require "mock_components"

module LaunchDarkly
  module Migrations
    describe MigratorBuilder do
      subject { MigratorBuilder }

      describe "can build" do
        it "when properly configured" do
          with_client(test_config) do |client|
            builder = subject.new(client)
            builder.read(->(_) { return true }, ->(_) { return true })
            builder.write(->(_) { return true }, ->(_) { return true })
            migrator = builder.build

            expect(migrator).to be_a LaunchDarkly::Interfaces::Migrations::Migrator
          end
        end

        it "can modify execution order" do
          [MigratorBuilder::EXECUTION_PARALLEL, MigratorBuilder::EXECUTION_RANDOM, MigratorBuilder::EXECUTION_SERIAL].each do |order|
            with_client(test_config) do |client|
              builder = subject.new(client)
              builder.read_execution_order(order)
              builder.read(->(_) { return true }, ->(_) { return true })
              builder.write(->(_) { return true }, ->(_) { return true })
              migrator = builder.build

              expect(migrator).to be_a LaunchDarkly::Interfaces::Migrations::Migrator
            end
          end
        end
      end

      describe "will fail to build" do
        it "if no client is provided" do
          error = subject.new(nil).build

          expect(error).to eq("client not provided")
        end

        it "if read config isn't provided" do
          with_client(test_config) do |client|
            error = subject.new(client).build

            expect(error).to eq("read configuration not provided")
          end
        end

        it "if read config has wrong arity" do
          with_client(test_config) do |client|
            builder = subject.new(client)
            builder.read(-> { return true }, -> { return true })
            error = builder.build

            expect(error).to eq("read configuration not provided")
          end
        end

        it "if read comparison has wrong arity" do
          with_client(test_config) do |client|
            builder = subject.new(client)
            builder.read(->(_) { return true }, ->(_) { return true }, ->(_) { return true })
            error = builder.build

            expect(error).to eq("read configuration not provided")
          end
        end

        it "if write config isn't provided" do
          with_client(test_config) do |client|
            builder = subject.new(client)
            builder.read(->(_) { return true }, ->(_) { return true })

            error = builder.build
            expect(error).to eq("write configuration not provided")
          end
        end

        it "if write config has wrong arity" do
          with_client(test_config) do |client|
            builder = subject.new(client)
            builder.read(->(_) { return true }, ->(_) { return true })
            builder.write(-> { return true }, -> { return true })
            error = builder.build

            expect(error).to eq("write configuration not provided")
          end
        end
      end
    end
  end
end
