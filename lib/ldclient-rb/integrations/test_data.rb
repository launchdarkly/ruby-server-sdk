require 'ldclient-rb/impl/integrations/test_data/test_data_source'
require 'ldclient-rb/impl/model/feature_flag'
require 'ldclient-rb/impl/model/segment'
require 'ldclient-rb/integrations/test_data/flag_builder'

require 'concurrent/atomics'

module LaunchDarkly
  module Integrations
    #
    # A mechanism for providing dynamically updatable feature flag state in a simplified form to an SDK
    # client in test scenarios.
    #
    # Unlike {LaunchDarkly::Integrations::FileData}, this mechanism does not use any external resources. It
    # provides only the data that the application has put into it using the {#update} method.
    #
    # @example
    #     td = LaunchDarkly::Integrations::TestData.data_source
    #     td.update(td.flag("flag-key-1").variation_for_all(true))
    #     config = LaunchDarkly::Config.new(data_source: td)
    #     client = LaunchDarkly::LDClient.new('sdkKey', config)
    #     # flags can be updated at any time:
    #     td.update(td.flag("flag-key-2")
    #                 .variation_for_key("user", some-user-key", true)
    #                 .fallthrough_variation(false))
    #
    # The above example uses a simple boolean flag, but more complex configurations are possible using
    # the methods of the {FlagBuilder} that is returned by {#flag}. {FlagBuilder}
    # supports many of the ways a flag can be configured on the LaunchDarkly dashboard, but does not
    # currently support 1. rule operators other than "in" and "not in", or 2. percentage rollouts.
    #
    # If the same `TestData` instance is used to configure multiple `LDClient` instances,
    # any changes made to the data will propagate to all of the `LDClient`s.
    #
    # @since 6.3.0
    #
    class TestData
      # Creates a new instance of the test data source.
      #
      # @return [TestData] a new configurable test data source
      def self.data_source
        self.new
      end

      # @private
      def initialize
        @flag_builders = Hash.new
        @current_flags = Hash.new
        @current_segments = Hash.new
        @instances = Array.new
        @instances_lock = Concurrent::ReadWriteLock.new
        @lock = Concurrent::ReadWriteLock.new
      end

      #
      # Called internally by the SDK to determine what arguments to pass to call
      # You do not need to call this method.
      #
      # @private
      def arity
        2
      end

      #
      # Called internally by the SDK to associate this test data source with an {@code LDClient} instance.
      # You do not need to call this method.
      #
      # @private
      def call(_, config)
        impl = LaunchDarkly::Impl::Integrations::TestData::TestDataSource.new(config.feature_store, self)
        @instances_lock.with_write_lock { @instances.push(impl) }
        impl
      end

      #
      # Creates or copies a {FlagBuilder} for building a test flag configuration.
      #
      # If this flag key has already been defined in this `TestData` instance, then the builder
      # starts with the same configuration that was last provided for this flag.
      #
      # Otherwise, it starts with a new default configuration in which the flag has `true` and
      # `false` variations, is `true` for all contexts when targeting is turned on and
      # `false` otherwise, and currently has targeting turned on. You can change any of those
      # properties, and provide more complex behavior, using the {FlagBuilder} methods.
      #
      # Once you have set the desired configuration, pass the builder to {#update}.
      #
      # @param key [String] the flag key
      # @return [FlagBuilder] a flag configuration builder
      #
      def flag(key)
        existing_builder = @lock.with_read_lock { @flag_builders[key] }
        if existing_builder.nil? then
          FlagBuilder.new(key).boolean_flag
        else
          existing_builder.clone
        end
      end

      #
      # Updates the test data with the specified flag configuration.
      #
      # This has the same effect as if a flag were added or modified on the LaunchDarkly dashboard.
      # It immediately propagates the flag change to any `LDClient` instance(s) that you have
      # already configured to use this `TestData`. If no `LDClient` has been started yet,
      # it simply adds this flag to the test data which will be provided to any `LDClient` that
      # you subsequently configure.
      #
      # Any subsequent changes to this {FlagBuilder} instance do not affect the test data,
      # unless you call {#update} again.
      #
      # @param flag_builder [FlagBuilder] a flag configuration builder
      # @return [TestData] the TestData instance
      #
      def update(flag_builder)
        new_flag = nil
        @lock.with_write_lock do
          @flag_builders[flag_builder.key] = flag_builder
          version = 0
          flag_key = flag_builder.key.to_sym
          if @current_flags[flag_key] then
            version = @current_flags[flag_key][:version]
          end
          new_flag = Impl::Model.deserialize(FEATURES, flag_builder.build(version+1))
          @current_flags[flag_key] = new_flag
        end
        update_item(FEATURES, new_flag)
        self
      end

      #
      # Copies a full feature flag data model object into the test data.
      #
      # It immediately propagates the flag change to any `LDClient` instance(s) that you have already
      # configured to use this `TestData`. If no `LDClient` has been started yet, it simply adds
      # this flag to the test data which will be provided to any LDClient that you subsequently
      # configure.
      #
      # Use this method if you need to use advanced flag configuration properties that are not supported by
      # the simplified {FlagBuilder} API. Otherwise it is recommended to use the regular {flag}/{update}
      # mechanism to avoid dependencies on details of the data model.
      #
      # You cannot make incremental changes with {flag}/{update} to a flag that has been added in this way;
      # you can only replace it with an entirely new flag configuration.
      #
      # @param flag [Hash] the flag configuration
      # @return [TestData] the TestData instance
      #
      def use_preconfigured_flag(flag)
        use_preconfigured_item(FEATURES, flag, @current_flags)
      end

      #
      # Copies a full segment data model object into the test data.
      #
      # It immediately propagates the change to any `LDClient` instance(s) that you have already
      # configured to use this `TestData`. If no `LDClient` has been started yet, it simply adds
      # this segment to the test data which will be provided to any LDClient that you subsequently
      # configure.
      #
      # This method is currently the only way to inject segment data, since there is no builder
      # API for segments. It is mainly intended for the SDK's own tests of segment functionality,
      # since application tests that need to produce a desired evaluation state could do so more easily
      # by just setting flag values.
      #
      # @param segment [Hash] the segment configuration
      # @return [TestData] the TestData instance
      #
      def use_preconfigured_segment(segment)
        use_preconfigured_item(SEGMENTS, segment, @current_segments)
      end

      private def use_preconfigured_item(kind, item, current)
        item = Impl::Model.deserialize(kind, item)
        key = item.key.to_sym
        @lock.with_write_lock do
          old_item = current[key]
          unless old_item.nil? then
            data = item.as_json
            data[:version] = old_item.version + 1
            item = Impl::Model.deserialize(kind, data)
          end
          current[key] = item
        end
        update_item(kind, item)
        self
      end

      private def update_item(kind, item)
        @instances_lock.with_read_lock do
          @instances.each do | instance |
            instance.upsert(kind, item)
          end
        end
      end

      # @private
      def make_init_data
        @lock.with_read_lock do
          {
            FEATURES => @current_flags.clone,
            SEGMENTS => @current_segments.clone,
          }
        end
      end

      # @private
      def closed_instance(instance)
        @instances_lock.with_write_lock { @instances.delete(instance) }
      end
    end
  end
end
