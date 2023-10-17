require 'thread'

module LaunchDarkly
  module Impl
    module Migrations

      #
      # A migration config stores references to callable methods which execute customer defined read or write
      # operations on old or new origins of information. For read operations, an optional comparison function also be
      # defined.
      #
      class MigrationConfig
        #
        # @param old [#call] Refer to {#old}
        # @param new [#call] Refer to {#new}
        # @param comparison [#call, nil] Refer to {#comparison}
        #
        def initialize(old, new, comparison)
          @old = old
          @new = new
          @comparison = comparison
        end

        #
        # Callable which receives a nullable payload parameter and returns an {LaunchDarkly::Result}.
        #
        # This function call should affect the old migration origin when called.
        #
        # @return [#call]
        #
        attr_reader :old

        #
        # Callable which receives a nullable payload parameter and returns an {LaunchDarkly::Result}.
        #
        # This function call should affect the new migration origin when called.
        #
        # @return [#call]
        #
        attr_reader :new

        #
        # Optional callable which receives two objects of any kind and returns a boolean representing equality.
        #
        # The result of this comparison can be sent upstream to LaunchDarkly to enhance migration observability.
        #
        # @return [#call, nil]
        #
        attr_reader :comparison
      end

      #
      # An implementation of the [LaunchDarkly::Interfaces::Migrations::Migrator] interface, capable of supporting
      # feature-flag backed technology migrations.
      #
      class Migrator
        include LaunchDarkly::Interfaces::Migrations::Migrator

        #
        # @param client [LaunchDarkly::LDClient]
        # @param read_execution_order [Symbol]
        # @param read_config [MigrationConfig]
        # @param write_config [MigrationConfig]
        # @param measure_latency [Boolean]
        # @param measure_errors [Boolean]
        #
        def initialize(client, read_execution_order, read_config, write_config, measure_latency, measure_errors)
          @client = client
          @read_execution_order = read_execution_order
          @read_config = read_config
          @write_config = write_config
          @measure_latency = measure_latency
          @measure_errors = measure_errors
          @sampler = LaunchDarkly::Impl::Sampler.new(Random.new)
        end

        #
        # Perform the configured read operations against the appropriate old and/or new origins.
        #
        # @param key [String] The migration-based flag key to use for determining migration stages
        # @param context [LaunchDarkly::LDContext] The context to use for evaluating the migration flag
        # @param default_stage [Symbol] The stage to fallback to if one could not be determined for the requested flag
        # @param payload [String] An optional payload to pass through to the configured read operations.
        #
        # @return [LaunchDarkly::Migrations::OperationResult]
        #
        def read(key, context, default_stage, payload = nil)
          stage, tracker = @client.migration_variation(key, context, default_stage)
          tracker.operation(LaunchDarkly::Migrations::OP_READ)

          old = Executor.new(@client.logger, LaunchDarkly::Migrations::ORIGIN_OLD, @read_config.old, tracker, @measure_latency, @measure_errors, payload)
          new = Executor.new(@client.logger, LaunchDarkly::Migrations::ORIGIN_NEW, @read_config.new, tracker, @measure_latency, @measure_errors, payload)

          case stage
          when LaunchDarkly::Migrations::STAGE_OFF
            result = old.run
          when LaunchDarkly::Migrations::STAGE_DUALWRITE
            result = old.run
          when LaunchDarkly::Migrations::STAGE_SHADOW
            result = read_both(old, new, @read_config.comparison, @read_execution_order, tracker)
          when LaunchDarkly::Migrations::STAGE_LIVE
            result = read_both(new, old, @read_config.comparison, @read_execution_order, tracker)
          when LaunchDarkly::Migrations::STAGE_RAMPDOWN
            result = new.run
          when LaunchDarkly::Migrations::STAGE_COMPLETE
            result = new.run
          else
            result = LaunchDarkly::Migrations::OperationResult.new(
              LaunchDarkly::Migrations::ORIGIN_OLD,
              LaunchDarkly::Result.fail("invalid stage #{stage}; cannot execute read")
            )
          end

          @client.track_migration_op(tracker)

          result
        end

        #
        # Perform the configured write operations against the appropriate old and/or new origins.
        #
        # @param key [String] The migration-based flag key to use for determining migration stages
        # @param context [LaunchDarkly::LDContext] The context to use for evaluating the migration flag
        # @param default_stage [Symbol] The stage to fallback to if one could not be determined for the requested flag
        # @param payload [String] An optional payload to pass through to the configured write operations.
        #
        # @return [LaunchDarkly::Migrations::WriteResult]
        #
        def write(key, context, default_stage, payload = nil)
          stage, tracker = @client.migration_variation(key, context, default_stage)
          tracker.operation(LaunchDarkly::Migrations::OP_WRITE)

          old = Executor.new(@client.logger, LaunchDarkly::Migrations::ORIGIN_OLD, @write_config.old, tracker, @measure_latency, @measure_errors, payload)
          new = Executor.new(@client.logger, LaunchDarkly::Migrations::ORIGIN_NEW, @write_config.new, tracker, @measure_latency, @measure_errors, payload)

          case stage
          when LaunchDarkly::Migrations::STAGE_OFF
            result = old.run()
            write_result = LaunchDarkly::Migrations::WriteResult.new(result)
          when LaunchDarkly::Migrations::STAGE_DUALWRITE
            authoritative_result, nonauthoritative_result = write_both(old, new, tracker)
            write_result = LaunchDarkly::Migrations::WriteResult.new(authoritative_result, nonauthoritative_result)
          when LaunchDarkly::Migrations::STAGE_SHADOW
            authoritative_result, nonauthoritative_result = write_both(old, new, tracker)
            write_result = LaunchDarkly::Migrations::WriteResult.new(authoritative_result, nonauthoritative_result)
          when LaunchDarkly::Migrations::STAGE_LIVE
            authoritative_result, nonauthoritative_result = write_both(new, old, tracker)
            write_result = LaunchDarkly::Migrations::WriteResult.new(authoritative_result, nonauthoritative_result)
          when LaunchDarkly::Migrations::STAGE_RAMPDOWN
            authoritative_result, nonauthoritative_result = write_both(new, old, tracker)
            write_result = LaunchDarkly::Migrations::WriteResult.new(authoritative_result, nonauthoritative_result)
          when LaunchDarkly::Migrations::STAGE_COMPLETE
            result = new.run()
            write_result = LaunchDarkly::Migrations::WriteResult.new(result)
          else
            result = LaunchDarkly::Migrations::OperationResult.fail(
              LaunchDarkly::Migrations::ORIGIN_OLD,
              LaunchDarkly::Result.fail("invalid stage #{stage}; cannot execute write")
            )
            write_result = LaunchDarkly::Migrations::WriteResult.new(result)
          end

          @client.track_migration_op(tracker)

          write_result
        end

        #
        # Execute both read methods in accordance with the requested execution order.
        #
        # This method always returns the {LaunchDarkly::Migrations::OperationResult} from running the authoritative read operation. The
        # non-authoritative executor may fail but it will not affect the return value.
        #
        # @param authoritative [Executor]
        # @param nonauthoritative [Executor]
        # @param comparison [#call]
        # @param execution_order [Symbol]
        # @param tracker [LaunchDarkly::Interfaces::Migrations::OpTracker]
        #
        # @return [LaunchDarkly::Migrations::OperationResult]
        #
        private def read_both(authoritative, nonauthoritative, comparison, execution_order, tracker)
          authoritative_result = nil
          nonauthoritative_result = nil

          case execution_order
          when LaunchDarkly::Migrations::MigratorBuilder::EXECUTION_PARALLEL
            auth_handler = Thread.new { authoritative_result = authoritative.run }
            nonauth_handler = Thread.new { nonauthoritative_result = nonauthoritative.run }

            auth_handler.join()
            nonauth_handler.join()
          when LaunchDarkly::Migrations::MigratorBuilder::EXECUTION_RANDOM && @sampler.sample(2)
            nonauthoritative_result = nonauthoritative.run
            authoritative_result = authoritative.run
          else
            authoritative_result = authoritative.run
            nonauthoritative_result = nonauthoritative.run
          end

          return authoritative_result if comparison.nil?

          if authoritative_result.success? && nonauthoritative_result.success?
            tracker.consistent(->{ comparison.call(authoritative_result.value, nonauthoritative_result.value) })
          end

          authoritative_result
        end

        #
        # Execute both operations sequentially.
        #
        # If the authoritative executor fails, do not run the non-authoritative one. As a result, this method will
        # always return an authoritative {LaunchDarkly::Migrations::OperationResult} as the first value, and optionally the non-authoritative
        # {LaunchDarkly::Migrations::OperationResult} as the second value.
        #
        # @param authoritative [Executor]
        # @param nonauthoritative [Executor]
        # @param tracker [LaunchDarkly::Interfaces::Migrations::OpTracker]
        #
        # @return [Array<LaunchDarkly::Migrations::OperationResult, [LaunchDarkly::Migrations::OperationResult, nil]>]
        #
        private def write_both(authoritative, nonauthoritative, tracker)
          authoritative_result = authoritative.run()
          tracker.invoked(authoritative.origin)

          return authoritative_result, nil unless authoritative_result.success?

          nonauthoritative_result = nonauthoritative.run()
          tracker.invoked(nonauthoritative.origin)

          [authoritative_result, nonauthoritative_result]
        end
      end

      #
      # Utility class for executing migration operations while also tracking our built-in migration measurements.
      #
      class Executor
        #
        # @return [Symbol]
        #
        attr_reader :origin

        #
        # @param origin [Symbol]
        # @param fn [#call]
        # @param tracker [LaunchDarkly::Interfaces::Migrations::OpTracker]
        # @param measure_latency [Boolean]
        # @param measure_errors [Boolean]
        # @param payload [Object, nil]
        #
        def initialize(logger, origin, fn, tracker, measure_latency, measure_errors, payload)
          @logger = logger
          @origin = origin
          @fn = fn
          @tracker = tracker
          @measure_latency = measure_latency
          @measure_errors = measure_errors
          @payload = payload
        end

        #
        # Execute the configured operation and track any available measurements.
        #
        # @return [LaunchDarkly::Migrations::OperationResult]
        #
        def run()
          start = Time.now

          begin
            result = @fn.call(@payload)
          rescue => e
            LaunchDarkly::Util.log_exception(@logger, "Unexpected error running method for '#{origin}' origin", e)
            result = LaunchDarkly::Result.fail("'#{origin}' operation raised an exception", e)
          end

          @tracker.latency(@origin, (Time.now - start) * 1_000) if @measure_latency
          @tracker.error(@origin) if @measure_errors && !result.success?
          @tracker.invoked(@origin)

          LaunchDarkly::Migrations::OperationResult.new(@origin, result)
        end
      end
    end
  end
end
