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

        private def initialize(value, error)
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
        def initialize(authoritative, nonauthoritative)
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

        def initialize(client, read_execution_order, read_config, write_config, measure_latency, measure_errors)
          @client = client
          @read_execution_order = read_execution_order
          @read_config = read_config
          @write_config = write_config
          @measure_latency = measure_latency
          @measure_errors = measure_errors
        end

        def read(key, context, default_stage, payload)
          # TODO(uc2-migrations): Implement this logic
        end

        def write(key, context, default_stage, payload)
          # TODO(uc2-migrations): Implement this logic
        end
      end
    end
  end
end
