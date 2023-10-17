require 'ldclient-rb/impl/migrations/migrator'

module LaunchDarkly
  #
  # Namespace for feature-flag based technology migration support.
  #
  module Migrations
    # Symbol representing the old origin, or the old technology source you are migrating away from.
    ORIGIN_OLD = :old
    # Symbol representing the new origin, or the new technology source you are migrating towards.
    ORIGIN_NEW = :new

    # Symbol defining a read-related operation
    OP_READ = :read
    # Symbol defining a write-related operation
    OP_WRITE = :write

    STAGE_OFF = :off
    STAGE_DUALWRITE = :dualwrite
    STAGE_SHADOW = :shadow
    STAGE_LIVE = :live
    STAGE_RAMPDOWN = :rampdown
    STAGE_COMPLETE = :complete

    VALID_OPERATIONS = [
      OP_READ,
      OP_WRITE,
    ]

    VALID_ORIGINS = [
      ORIGIN_OLD,
      ORIGIN_NEW,
    ]

    VALID_STAGES = [
      STAGE_OFF,
      STAGE_DUALWRITE,
      STAGE_SHADOW,
      STAGE_LIVE,
      STAGE_RAMPDOWN,
      STAGE_COMPLETE,
    ]

    #
    # The OperationResult wraps the {LaunchDarkly::Result} class to tie an operation origin to a result.
    #
    class OperationResult
      extend Forwardable
      def_delegators :@result, :value, :error, :exception, :success?

      #
      # @param origin [Symbol]
      # @param result [LaunchDarkly::Result]
      #
      def initialize(origin, result)
        @origin = origin
        @result = result
      end

      #
      # @return [Symbol] The origin this result is associated with.
      #
      attr_reader :origin
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

        @read_config = nil # @type [LaunchDarkly::Impl::Migrations::MigrationConfig, nil]
        @write_config = nil # @type [LaunchDarkly::Impl::Migrations::MigrationConfig, nil]
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
      # Depending on the migration stage, one or both of these read methods may be called.
      #
      # The read methods should accept a single nullable parameter. This parameter is a payload passed through the
      # {LaunchDarkly::Interfaces::Migrations::Migrator#read} method. This method should return a {LaunchDarkly::Result}
      # instance.
      #
      # The consistency method should accept 2 parameters of any type. These parameters are the results of executing the
      # read operation against the old and new origins. If both operations were successful, the consistency method will
      # be invoked. This method should return true if the two parameters are equal, or false otherwise.
      #
      # @param old_read [#call]
      # @param new_read [#call]
      # @param comparison [#call, nil]
      #
      def read(old_read, new_read, comparison = nil)
        return unless old_read.respond_to?(:call) && old_read.arity == 1
        return unless new_read.respond_to?(:call) && new_read.arity == 1
        return unless comparison.nil? || (comparison.respond_to?(:call) && comparison.arity == 2)

        @read_config = LaunchDarkly::Impl::Migrations::MigrationConfig.new(old_read, new_read, comparison)
      end

      #
      # Write can be used to configure the migration-write behavior of the resulting
      # {LaunchDarkly::Interfaces::Migrations::Migrator} instance.
      #
      # Users are required to provide two different write methods -- one to write to the old migration origin, and one
      # to write to the new origin.
      #
      # Depending on the migration stage, one or both of these write methods may be called.
      #
      # The write methods should accept a single nullable parameter. This parameter is a payload passed through the
      # {LaunchDarkly::Interfaces::Migrations::Migrator#write} method. This method should return a {LaunchDarkly::Result}
      # instance.
      #
      # @param old_write [#call]
      # @param new_write [#call]
      #
      def write(old_write, new_write)
        return unless old_write.respond_to?(:call) && old_write.arity == 1
        return unless new_write.respond_to?(:call) && new_write.arity == 1

        @write_config = LaunchDarkly::Impl::Migrations::MigrationConfig.new(old_write, new_write, nil)
      end

      #
      # Build constructs a {LaunchDarkly::Interfaces::Migrations::Migrator} instance to support migration-based reads
      # and writes. A string describing any failure conditions will be returned if the build fails.
      #
      # @return [LaunchDarkly::Interfaces::Migrations::Migrator, string]
      #
      def build
        return "client not provided" if @client.nil?
        return "read configuration not provided" if @read_config.nil?
        return "write configuration not provided" if @write_config.nil?

        LaunchDarkly::Impl::Migrations::Migrator.new(@client, @read_execution_order, @read_config, @write_config, @measure_latency, @measure_errors)
      end
    end

  end
end
