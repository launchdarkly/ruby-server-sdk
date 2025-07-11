module LaunchDarkly
  module Interfaces
    #
    # Namespace for feature-flag based technology migration support.
    #
    module Migrations
      #
      # A migrator is the interface through which migration support is executed. A migrator is configured through the
      # {LaunchDarkly::Migrations::MigratorBuilder} class.
      #
      module Migrator
        #
        # Uses the provided flag key and context to execute a migration-backed read operation.
        #
        # @param key [String]
        # @param context [LaunchDarkly::LDContext]
        # @param default_stage [Symbol]
        # @param payload [Object, nil]
        #
        # @return [LaunchDarkly::Migrations::OperationResult]
        #
        def read(key, context, default_stage, payload = nil) end

        #
        # Uses the provided flag key and context to execute a migration-backed write operation.
        #
        # @param key [String]
        # @param context [LaunchDarkly::LDContext]
        # @param default_stage [Symbol]
        # @param payload [Object, nil]
        #
        # @return [LaunchDarkly::Migrations::WriteResult]
        #
        def write(key, context, default_stage, payload = nil) end
      end

      #
      # An OpTracker is responsible for managing the collection of measurements that which a user might wish to record
      # throughout a migration-assisted operation.
      #
      # Example measurements include latency, errors, and consistency.
      #
      # This data can be provided to the {LaunchDarkly::LDClient.track_migration_op} method to relay this metric
      # information upstream to LaunchDarkly services.
      #
      module OpTracker
        #
        # Sets the migration related operation associated with these tracking measurements.
        #
        # @param [Symbol] op The read or write operation symbol.
        #
        def operation(op) end

        #
        # Allows recording which origins were called during a migration.
        #
        # @param [Symbol] origin Designation for the old or new origin.
        #
        def invoked(origin) end

        #
        # Allows recording the results of a consistency check.
        #
        # This method accepts a callable which should take no parameters and return a single boolean to represent the
        # consistency check results for a read operation.
        #
        # A callable is provided in case sampling rules do not require consistency checking to run. In this case, we can
        # avoid the overhead of a function by not using the callable.
        #
        # @param [#call] is_consistent closure to return result of comparison check
        #
        def consistent(is_consistent) end

        #
        # Allows recording whether an error occurred during the operation.
        #
        # @param [Symbol] origin Designation for the old or new origin.
        #
        def error(origin) end

        #
        # Allows tracking the recorded latency for an individual operation.
        #
        # @param [Symbol] origin Designation for the old or new origin.
        # @param [Float] duration Duration measurement in milliseconds (ms).
        #
        def latency(origin, duration) end

        #
        # Creates an instance of {LaunchDarkly::Impl::MigrationOpEventData}.
        #
        # @return [LaunchDarkly::Impl::MigrationOpEvent, String] A migration op event or a string describing the error.
        # failure.
        #
        def build
        end
      end
    end
  end
end
