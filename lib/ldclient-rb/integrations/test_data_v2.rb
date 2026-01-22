require 'ldclient-rb/impl/integrations/test_data/test_data_source_v2'
require 'ldclient-rb/impl/model/feature_flag'
require 'ldclient-rb/integrations/test_data_v2/flag_builder_v2'
require 'concurrent/atomics'

module LaunchDarkly
  module Integrations
    #
    # A mechanism for providing dynamically updatable feature flag state in a
    # simplified form to an SDK client in test scenarios using the FDv2 protocol.
    #
    # This type is not stable, and not subject to any backwards
    # compatibility guarantees or semantic versioning. It is not suitable for production usage.
    #
    # Do not use it.
    # You have been warned.
    #
    # Unlike {LaunchDarkly::Integrations::FileData}, this mechanism does not use any external resources. It
    # provides only the data that the application has put into it using the {#update} method.
    #
    # @example
    #     require 'ldclient-rb/integrations/test_data_v2'
    #
    #     td = LaunchDarkly::Integrations::TestDataV2.data_source
    #     td.update(td.flag('flag-key-1').variation_for_all(true))
    #
    #     # Configure the data system with TestDataV2 as both initializer and synchronizer
    #     # Note: This example assumes FDv2 data system configuration is available
    #     # data_config = LaunchDarkly::Impl::DataSystem::Config.custom
    #     # data_config.initializers([td.method(:build_initializer)])
    #     # data_config.synchronizers(td.method(:build_synchronizer))
    #
    #     # config = LaunchDarkly::Config.new(
    #     #   sdk_key,
    #     #   data_system_config: data_config.build
    #     # )
    #
    #     # flags can be updated at any time:
    #     td.update(td.flag('flag-key-1')
    #         .variation_for_user('some-user-key', true)
    #         .fallthrough_variation(false))
    #
    # The above example uses a simple boolean flag, but more complex configurations are possible using
    # the methods of the {FlagBuilderV2} that is returned by {#flag}. {FlagBuilderV2}
    # supports many of the ways a flag can be configured on the LaunchDarkly dashboard, but does not
    # currently support 1. rule operators other than "in" and "not in", or 2. percentage rollouts.
    #
    # If the same `TestDataV2` instance is used to configure multiple `LDClient` instances,
    # any changes made to the data will propagate to all of the `LDClient` instances.
    #
    class TestDataV2
      # Creates a new instance of the test data source.
      #
      # @return [TestDataV2] a new configurable test data source
      def self.data_source
        self.new
      end

      # @api private
      def initialize
        @flag_builders = Hash.new
        @current_flags = Hash.new
        @current_segments = Hash.new
        @lock = Concurrent::ReadWriteLock.new
        @instances = Array.new
        @version = 0
      end

      #
      # Creates or copies a {FlagBuilderV2} for building a test flag configuration.
      #
      # If this flag key has already been defined in this `TestDataV2` instance, then the builder
      # starts with the same configuration that was last provided for this flag.
      #
      # Otherwise, it starts with a new default configuration in which the flag has `true` and
      # `false` variations, is `true` for all contexts when targeting is turned on and
      # `false` otherwise, and currently has targeting turned on. You can change any of those
      # properties, and provide more complex behavior, using the {FlagBuilderV2} methods.
      #
      # Once you have set the desired configuration, pass the builder to {#update}.
      #
      # @param key [String] the flag key
      # @return [FlagBuilderV2] a flag configuration builder
      #
      def flag(key)
        existing_builder = @lock.with_read_lock do
          if @flag_builders.key?(key) && !@flag_builders[key].nil?
            @flag_builders[key]
          else
            nil
          end
        end

        if existing_builder.nil?
          LaunchDarkly::Integrations::TestDataV2::FlagBuilderV2.new(key).boolean_flag
        else
          existing_builder.clone
        end
      end

      #
      # Updates the test data with the specified flag configuration.
      #
      # This has the same effect as if a flag were added or modified on the LaunchDarkly dashboard.
      # It immediately propagates the flag change to any `LDClient` instance(s) that you have
      # already configured to use this `TestDataV2`. If no `LDClient` has been started yet,
      # it simply adds this flag to the test data which will be provided to any `LDClient` that
      # you subsequently configure.
      #
      # Any subsequent changes to this {FlagBuilderV2} instance do not affect the test data,
      # unless you call {#update} again.
      #
      # @param flag_builder [FlagBuilderV2] a flag configuration builder
      # @return [TestDataV2] the TestDataV2 instance
      #
      def update(flag_builder)
        instances_copy = []
        new_flag = nil
        @lock.with_write_lock do
          old_flag = @current_flags[flag_builder._key]
          old_version = old_flag ? old_flag[:version] : 0

          new_flag = flag_builder.build(old_version + 1)

          @current_flags[flag_builder._key] = new_flag
          @flag_builders[flag_builder._key] = flag_builder.clone

          # Create a copy of instances while holding the lock to avoid race conditions
          instances_copy = @instances.dup
        end

        instances_copy.each do |instance|
          instance.upsert_flag(new_flag)
        end

        self
      end

      # @api private
      def make_init_data
        @lock.with_read_lock do
          {
            flags: @current_flags.dup,
            segments: @current_segments.dup,
          }
        end
      end

      # @api private
      def get_version
        @lock.with_write_lock do
          version = @version
          @version += 1
          version
        end
      end

      # @api private
      # @param instance [LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2] the TestDataSourceV2 instance to remove
      def closed_instance(instance)
        @lock.with_write_lock do
          @instances.delete(instance) if @instances.include?(instance)
        end
      end

      # @api private
      # @param instance [LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2] the TestDataSourceV2 instance to add
      def add_instance(instance)
        @lock.with_write_lock do
          @instances.push(instance)
        end
      end

      #
      # Copies a full segment data model object into the test data.
      #
      # It immediately propagates the change to any `LDClient` instance(s) that you have already
      # configured to use this `TestDataV2`. If no `LDClient` has been started yet, it simply adds
      # this segment to the test data which will be provided to any LDClient that you subsequently
      # configure.
      #
      # This method is currently the only way to inject segment data, since there is no builder
      # API for segments. It is mainly intended for the SDK's own tests of segment functionality,
      # since application tests that need to produce a desired evaluation state could do so more easily
      # by just setting flag values.
      #
      # @param segment [Hash, LaunchDarkly::Impl::Model::Segment] the segment configuration as a hash or
      #   a Segment model object.
      # @return [TestDataV2] the TestDataV2 instance
      #
      def use_preconfigured_segment(segment)
        instances_copy = []
        segment_key = nil
        updated_segment = nil

        @lock.with_write_lock do
          # Convert to hash and normalize keys to symbols
          segment_hash = if segment.is_a?(Hash)
            segment.transform_keys(&:to_sym)
          else
            segment.as_json
          end
          segment_key = segment_hash[:key]

          old_segment = @current_segments[segment_key]
          old_version = old_segment ? old_segment[:version] : 0

          updated_segment = segment_hash.dup
          updated_segment[:version] = old_version + 1

          @current_segments[segment_key] = updated_segment

          # Create a copy of instances while holding the lock to avoid race conditions
          instances_copy = @instances.dup
        end

        instances_copy.each do |instance|
          instance.upsert_segment(updated_segment)
        end

        self
      end

      #
      # Creates an initializer that can be used with the FDv2 data system.
      #
      # @param sdk_key [String] the SDK key
      # @param config [LaunchDarkly::Config] the SDK configuration
      # @return [LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2] a test data initializer
      #
      def build_initializer(sdk_key, config)
        LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2.new(self)
      end

      #
      # Creates a synchronizer that can be used with the FDv2 data system.
      #
      # @param sdk_key [String] the SDK key
      # @param config [LaunchDarkly::Config] the SDK configuration
      # @return [LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2] a test data synchronizer
      #
      def build_synchronizer(sdk_key, config)
        LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2.new(self)
      end
    end
  end
end

