require 'thread'

module LaunchDarkly
  module Impl
    module Migrations

      #
      # An operation result can either succeed or it can fail. If the operation succeeded, no error will be present, and
      # an optionally non-nil value can be retrieved.
      #
      # In the event of a failure, the value will be nil and the error will be a string describing the failure
      # circumstances.
      #
      class OperationResult
        #
        # Create a successful operation result with the provided value.
        #
        # @param origin [Symbol]
        # @param value [Object, nil]
        # @return [OperationResult]
        #
        def self.success(origin, value)
          OperationResult.new(origin, value, nil)
        end

        #
        # Create a failed operation result with the provided error description.
        #
        # @param origin [Symbol]
        # @param error [String]
        # @return [OperationResult]
        #
        def self.fail(origin, error)
          OperationResult.new(origin, nil, error)
        end

        #
        # Was this result successful or did it encounter an error?
        #
        # @return [Boolean]
        #
        def success?()
          @error.nil?
        end

        #
        # @return [Symbol] The origin this result is associated with.
        #
        attr_reader :origin

        #
        # @return [Object, nil] The value returned from the migration operation if it was successful; nil otherwise.
        #
        attr_reader :value

        #
        # @return [String, nil] An error description of the failure; nil otherwise
        #
        attr_reader :error

        private def initialize(origin, value, error)
          @origin = origin
          @value = value
          @error = error
        end
      end

      #
      # A write result contains the operation results against both the authoritative and non-authoritative origins.
      #
      # Authoritative writes are always executed first. In the event of a failure, the non-authoritative write will not
      # be executed, resulting in a nil value in the final WriteResult.
      #
      class WriteResult
        #
        # @param authoritative [OperationResult]
        # @param nonauthoritative [OperationResult, nil]
        #
        def initialize(authoritative, nonauthoritative = nil)
          @authoritative = authoritative
          @nonauthoritative = nonauthoritative
        end

        #
        # Returns the operation result for the authoritative origin.
        #
        # @return [OperationResult]
        #
        attr_reader :authoritative

        #
        # Returns the operation result for the non-authoritative origin.
        #
        # This result might be nil as the non-authoritative write does not execute in every stage, and will not execute
        # if the authoritative write failed.
        #
        # @return [OperationResult, nil]
        #
        attr_reader :nonauthoritative
      end

      #
      # A migration config stores references to callable methods which execution customer defined read or write
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
        # Callable which receives a nullable payload parameter and returns an {OperationResult}.
        #
        # This function call should affect the old migration origin when called.
        #
        # @return [#call]
        #
        attr_reader :old

        #
        # Callable which receives a nullable payload parameter and returns an {OperationResult}.
        #
        # This function call should affect the new migration origin when called.
        #
        # @return [#call]
        #
        attr_reader :new

        #
        # Optional callable which receives two {OperationResult} objects and returns a boolean representing equality.
        #
        # The result of this comparison can be sent upstream to LaunchDarkly to enhance migration observability.
        #
        # @return [#call, nil]
        #
        attr_reader :comparison
      end

      #
      # The migration builder is used to configure and construct an instance of a
      # {LaunchDarkly::Interfaces::Migrations::Migrator}. This migrator can be used to perform LaunchDarkly assisted
      # technology migrations through the use of migration-based feature flags.
      #
      class MigratorBuilder
        EXECUTION_SERIAL = :serial
        EXECUTION_RANDOM = :random
        EXECUTION_PARALLEL = :parallel

        VALID_EXECUTION_ORDERS = [EXECUTION_SERIAL, EXECUTION_RANDOM, EXECUTION_PARALLEL]
        private_constant :VALID_EXECUTION_ORDERS

        #
        # @param client [LaunchDarkly::LDClient]
        #
        def initialize(client)
          @client = client

          # Default settings as required by the spec
          @read_execution_order = EXECUTION_PARALLEL
          @measure_latency = true
          @measure_errors = true

          @read_config = nil # @type [MigrationConfig, nil]
          @write_config = nil # @type [MigrationConfig, nil]
        end

        #
        # The read execution order influences the parallelism and execution order for read operations involving multiple
        # origins.
        #
        # @param order [Symbol]
        #
        def read_execution_order(order)
          return unless VALID_EXECUTION_ORDERS.include? order

          @read_execution_order = order
        end

        #
        # Enable or disable latency tracking for migration operations. This latency information can be sent upstream to
        # LaunchDarkly to enhance migration visibility.
        #
        # @param enabled [Boolean]
        #
        def track_latency(enabled)
          @measure_latency = !!enabled
        end

        #
        # Enable or disable error tracking for migration operations. This error information can be sent upstream to
        # LaunchDarkly to enhance migration visibility.
        #
        # @param enabled [Boolean]
        #
        def track_errors(enabled)
          @measure_errors = !!enabled
        end

        #
        # Read can be used to configure the migration-read behavior of the resulting
        # {LaunchDarkly::Interfaces::Migrations::Migrator} instance.
        #
        # Users are required to provide two different read methods -- one to read from the old migration origin, and one
        # to read from the new origin. Additionally, customers can opt-in to consistency tracking by providing a
        # comparison function.
        #
        # To learn more about these function signatures, refer to {MigrationConfig#old}, {MigrationConfig#new}, and
        # {MigrationConfig#comparison}
        #
        # Depending on the migration stage, one or both of these read methods may be called.
        #
        # @param old_read [#call]
        # @param new_read [#call]
        # @param comparison [#call, nil]
        #
        def read(old_read, new_read, comparison = nil)
          return unless old_read.respond_to?(:call) && old_read.arity == 1
          return unless new_read.respond_to?(:call) && new_read.arity == 1
          return unless comparison.nil? || (comparison.respond_to?(:call) && comparison.arity == 2)

          @read_config = MigrationConfig.new(old_read, new_read, comparison)
        end

        #
        # Write can be used to configure the migration-write behavior of the resulting
        # {LaunchDarkly::Interfaces::Migrations::Migrator} instance.
        #
        # Users are required to provide two different write methods -- one to write to the old migration origin, and one
        # to write to the new origin. Not every stage requires
        #
        # To learn more about these function signatures, refer to {MigrationConfig#old} and {MigrationConfig#new}.
        #
        # Depending on the migration stage, one or both of these write methods may be called.
        #
        # @param old_write [#call]
        # @param new_write [#call]
        #
        def write(old_write, new_write)
          return unless old_write.respond_to?(:call) && old_write.arity == 1
          return unless new_write.respond_to?(:call) && new_write.arity == 1

          @write_config = MigrationConfig.new(old_write, new_write, nil)
        end

        #
        # Build constructs a {LaunchDarkly::Interfaces::Migrations::Migrator} instance to support migration-based reads
        # and writes. A string describing any failure conditions will be returned if the build fails.
        #
        # @return [LaunchDarkly::Interfaces::Migrations::Migrator, string]
        #
        def build()
          return "client not provided" if @client.nil?
          return "read configuration not provided" if @read_config.nil?
          return "write configuration not provided" if @write_config.nil?

          Migrator.new(@client, @read_execution_order, @read_config, @write_config, @measure_latency, @measure_errors)
        end
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
        end

        #
        # Perform the configured read operations against the appropriate old and/or new origins.
        #
        # @param key [String] The migration-based flag key to use for determining migration stages
        # @param context [LaunchDarkly::LDContext] The context to use for evaluating the migration flag
        # @param default_stage [Symbol] The stage to fallback to if one could not be determined for the requested flag
        # @param payload [String] An optional payload to pass through to the configured read operations.
        #
        def read(key, context, default_stage, payload = nil)
          stage, tracker, err = @client.migration_variation(key, context, default_stage)
          tracker.operation(LaunchDarkly::Interfaces::Migrations::OP_READ)

          unless err.nil?
            @client.logger.error { "[Migrator] Error occurred determining migration stage for read; #{err}" }
          end

          old = Executor.new(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, @read_config.old, tracker, @measure_latency, @measure_errors, payload)
          new = Executor.new(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, @read_config.new, tracker, @measure_latency, @measure_errors, payload)

          case stage
          when LaunchDarkly::Interfaces::Migrations::STAGE_OFF
            result = old.run
          when LaunchDarkly::Interfaces::Migrations::STAGE_DUALWRITE
            result = old.run
          when LaunchDarkly::Interfaces::Migrations::STAGE_SHADOW
            result = read_both(old, new, @read_config.comparison, @read_execution_order, tracker)
          when LaunchDarkly::Interfaces::Migrations::STAGE_LIVE
            result = read_both(new, old, @read_config.comparison, @read_execution_order, tracker)
          when LaunchDarkly::Interfaces::Migrations::STAGE_RAMPDOWN
            result = new.run
          when LaunchDarkly::Interfaces::Migrations::STAGE_COMPLETE
            result = new.run
          else
            result = OperationResult.fail(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, "invalid stage #{stage}; cannot execute read")
          end

          event = tracker.build
          if event.is_a? String
            @client.logger.error { "[Migrator] Error occurred generating migration op event; #{event}" }
          else
            @client.track_migration_op(event)
          end

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
        def write(key, context, default_stage, payload = nil)
          stage, tracker, err = @client.migration_variation(key, context, default_stage)
          tracker.operation(LaunchDarkly::Interfaces::Migrations::OP_READ)

          unless err.nil?
            @client.logger.error { "[Migrator] Error occurred determining migration stage for write; #{err}" }
          end

          old = Executor.new(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, @write_config.old, tracker, @measure_latency, @measure_errors, payload)
          new = Executor.new(LaunchDarkly::Interfaces::Migrations::ORIGIN_NEW, @write_config.new, tracker, @measure_latency, @measure_errors, payload)

          case stage
          when LaunchDarkly::Interfaces::Migrations::STAGE_OFF
            result = old.run()
            write_result = WriteResult.new(result)
          when LaunchDarkly::Interfaces::Migrations::STAGE_DUALWRITE
            authoritative_result, nonauthoritative_result = write_both(old, new, tracker)
            write_result = WriteResult.new(authoritative_result, nonauthoritative_result)
          when LaunchDarkly::Interfaces::Migrations::STAGE_SHADOW
            authoritative_result, nonauthoritative_result = write_both(old, new, tracker)
            write_result = WriteResult.new(authoritative_result, nonauthoritative_result)
          when LaunchDarkly::Interfaces::Migrations::STAGE_LIVE
            authoritative_result, nonauthoritative_result = write_both(new, old, tracker)
            write_result = WriteResult.new(authoritative_result, nonauthoritative_result)
          when LaunchDarkly::Interfaces::Migrations::STAGE_RAMPDOWN
            authoritative_result, nonauthoritative_result = write_both(new, old, tracker)
            write_result = WriteResult.new(authoritative_result, nonauthoritative_result)
          when LaunchDarkly::Interfaces::Migrations::STAGE_COMPLETE
            result = new.run()
            write_result = WriteResult.new(result)
          else
            result = OperationResult.fail(LaunchDarkly::Interfaces::Migrations::ORIGIN_OLD, "invalid stage #{stage}; cannot execute write")
            write_result = WriteResult.new(result)
          end

          event = tracker.build()
          if event.is_a? String
            @client.logger.error { "[Migrator] Error occurred generating migration op event; #{event}" }
          else
            @client.track_migration_op(event)
          end

          write_result
        end

        #
        # Execute both read methods in accordance with the requested execution order.
        #
        # This method always returns the {OperationResult} from running the authoritative read operation. The
        # non-authoritative executor may fail but it will not affect the return value.
        #
        # @param authoritative [Executor]
        # @param nonauthoritative [Executor]
        # @param comparison [#call]
        # @param execution_order [Symbol]
        # @param tracker [LaunchDarkly::Interfaces::Migrations::OpTracker]
        #
        # @return [OperationResult]
        #
        private def read_both(authoritative, nonauthoritative, comparison, execution_order, tracker)
          authoritative_result = nil
          nonauthoritative_result = nil

          case execution_order
          when LaunchDarkly::Impl::Migrations::MigratorBuilder::EXECUTION_PARALLEL
            auth_handler = Thread.new { authoritative_result = authoritative.run() }
            nonauth_handler = Thread.new { nonauthoritative_result = nonauthoritative.run() }

            auth_handler.join()
            nonauth_handler.join()
          when LaunchDarkly::Impl::Migrations::MigratorBuilder::EXECUTION_RANDOM && rand() > 0.5
            nonauthoritative_result = nonauthoritative.run()
            authoritative_result = authoritative.run()
          else
            authoritative_result = authoritative.run()
            nonauthoritative_result = nonauthoritative.run()
          end

          unless comparison.nil?
            tracker.consistent(->{ return comparison.call(authoritative_result, nonauthoritative_result) })
          end

          authoritative_result
        end

        #
        # Execute both operations sequentially.
        #
        # If the authoritative executor fails, do not run the non-authoritative one. As a result, this method will
        # always return an authoritative {OperationResult} as the first value, and optionally the non-authoritative
        # {OperationResult} as the second value.
        #
        # @param authoritative [Executor]
        # @param nonauthoritative [Executor]
        # @param tracker [LaunchDarkly::Interfaces::Migrations::OpTracker]
        #
        # @return [Array<OperationResult, [OperationResult, nil]>]
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
        def initialize(origin, fn, tracker, measure_latency, measure_errors, payload)
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
        # @return [OperationResult]
        #
        def run()
          start = Time.now
          result = @fn.call(@payload)

          @tracker.latency(result.origin, (Time.now - start) * 1_000) if @measure_latency
          @tracker.error(result.origin) if @measure_errors && !result.success?
          @tracker.invoked(result.origin)

          result
        end
      end
    end
  end
end
