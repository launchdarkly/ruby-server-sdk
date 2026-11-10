require 'ldclient-rb/impl/integrations/test_data/test_data_source_v2'
require 'ldclient-rb/impl/model/feature_flag'
require 'ldclient-rb/impl/model/serialization'
require 'ldclient-rb/integrations/test_data_v2/flag_builder_v2'
require 'concurrent/atomics'
require 'json'
require 'set'

module LaunchDarkly
  module Integrations
    #
    # A mechanism for providing dynamically updatable feature flag state in a
    # simplified form to an SDK client in test scenarios using the FDv2 protocol.
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
        # Serializes each change with its delivery, so that every instance receives changes in the order
        # that they are made.
        @update_lock = Mutex.new
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
        key = key.to_s
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
        @update_lock.synchronize do
          instances_copy = []
          new_flag = nil
          @lock.with_write_lock do
            flag_key = flag_builder._key.to_sym
            old_flag = @current_flags[flag_key]
            old_version = old_flag ? old_flag[:version] : 0

            new_flag = flag_builder.build(old_version + 1)

            @current_flags[flag_key] = new_flag
            @flag_builders[flag_builder._key] = flag_builder.clone

            # Create a copy of instances while holding the lock to avoid race conditions
            instances_copy = @instances.dup
          end

          instances_copy.each do |instance|
            instance.upsert_flag(new_flag)
          end
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
      #
      # Adds an instance and takes the current data in one step. The instance then receives each
      # change that the returned data does not hold, and no change that it holds.
      #
      # @param instance [LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2] the TestDataSourceV2 instance to add
      # @return [Array(Hash, Integer)] the data, in the form of {#make_init_data}, and the next version
      def subscribe(instance)
        @lock.with_write_lock do
          @instances.push(instance)
          version = @version
          @version += 1
          [{ flags: @current_flags.dup, segments: @current_segments.dup }, version]
        end
      end

      #
      # Copies a full feature flag data model object into the test data.
      #
      # It immediately propagates the change to any `LDClient` instance(s) that you have already
      # configured to use this `TestDataV2`. If no `LDClient` has been started yet, it simply adds
      # this flag to the test data which will be provided to any LDClient that you subsequently
      # configure.
      #
      # Use this method if you need to use advanced flag configuration properties that are not supported by
      # the simplified {FlagBuilderV2} API. Otherwise use the regular {#flag}/{#update} mechanism to avoid
      # dependencies on details of the data model.
      #
      # You cannot make incremental changes with {#flag}/{#update} to a flag that you add in this way.
      # You can only replace it with an entirely new flag configuration.
      #
      # The flag keeps its own version if that version is greater than the version of any flag that it
      # replaces. Otherwise, it gets a version one more than the version of the flag that it replaces, or
      # version 1 if it is a new flag.
      #
      # The method stores a copy of the flag, so later changes to the object that you pass in have no effect.
      #
      # @param flag [Hash, String, LaunchDarkly::Impl::Model::FeatureFlag] the flag configuration as a hash
      #   with symbol or string keys, a JSON string, or a FeatureFlag model object.
      # @return [TestDataV2] the TestDataV2 instance
      # @raise [ArgumentError] if the flag is not a valid flag configuration
      #
      def use_preconfigured_flag(flag)
        flag_data = normalize_preconfigured_item(LaunchDarkly::Interfaces::DataStore::FEATURES, flag, "flag")

        @update_lock.synchronize do
          instances_copy = []
          @lock.with_write_lock do
            flag_key = flag_data[:key].to_sym
            old_flag = @current_flags[flag_key]
            next_version = (old_flag.nil? ? 0 : old_flag[:version]) + 1
            flag_data[:version] = [flag_data[:version] || 0, next_version].max

            @current_flags[flag_key] = flag_data
            @flag_builders.delete(flag_data[:key])

            instances_copy = @instances.dup
          end

          instances_copy.each do |instance|
            instance.upsert_flag(flag_data)
          end
        end

        self
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
      # The segment gets a version one more than the version of the segment that it replaces, or version 1
      # if it is a new segment. The method stores a copy of the segment, so later changes to the object that
      # you pass in have no effect.
      #
      # @param segment [Hash, String, LaunchDarkly::Impl::Model::Segment] the segment configuration as a hash
      #   with symbol or string keys, a JSON string, or a Segment model object.
      # @return [TestDataV2] the TestDataV2 instance
      # @raise [ArgumentError] if the segment is not a valid segment configuration
      #
      def use_preconfigured_segment(segment)
        segment_data = normalize_preconfigured_item(LaunchDarkly::Interfaces::DataStore::SEGMENTS, segment, "segment")

        @update_lock.synchronize do
          instances_copy = []
          @lock.with_write_lock do
            segment_key = segment_data[:key].to_sym
            old_segment = @current_segments[segment_key]
            segment_data[:version] = (old_segment ? old_segment[:version] : 0) + 1

            @current_segments[segment_key] = segment_data

            # Create a copy of instances while holding the lock to avoid race conditions
            instances_copy = @instances.dup
          end

          instances_copy.each do |instance|
            instance.upsert_segment(segment_data)
          end
        end

        self
      end

      # The maximum depth of nested hashes and arrays in a preconfigured item.
      MAX_PRECONFIGURED_DEPTH = 100
      private_constant :MAX_PRECONFIGURED_DEPTH

      #
      # Converts a preconfigured flag or segment to a new hash with symbol keys at every level, and checks
      # that it is a valid data model object.
      #
      # @param kind [LaunchDarkly::Interfaces::DataStore::DataKind] the kind of the item
      # @param item [Hash, String, Object] the item as a hash, a JSON string, or a model object
      # @param description [String] the name of the kind, for error messages
      # @return [Hash] the normalized item
      # @raise [ArgumentError] if the item is not valid
      #
      private def normalize_preconfigured_item(kind, item, description)
        raw =
          if item.is_a?(String)
            begin
              JSON.parse(item)
            rescue JSON::ParserError => e
              raise ArgumentError, "a preconfigured #{description} is not valid JSON: #{e.message}"
            end
          elsif item.is_a?(Hash)
            item
          elsif item.respond_to?(:as_json)
            item.as_json
          else
            raise ArgumentError, "a preconfigured #{description} must be a Hash, a JSON string, or a model object"
          end

        raise ArgumentError, "a preconfigured #{description} must be a JSON object" unless raw.is_a?(Hash)

        data = normalize_json_value(raw, description, "", 0)

        key = data[:key]
        unless key.is_a?(String) && !key.empty?
          raise ArgumentError, "a preconfigured #{description} must have a non-empty string key"
        end

        version = data[:version]
        unless version.nil? || version.is_a?(Integer)
          raise ArgumentError, "the version of preconfigured #{description} '#{key}' must be an integer"
        end

        begin
          LaunchDarkly::Impl::Model.deserialize(kind, data)
        rescue => e
          raise ArgumentError, "preconfigured #{description} '#{key}' is not valid: #{e.message}"
        end

        data
      end

      #
      # Returns a copy of a JSON-compatible value with symbol hash keys at every level. A Set becomes an
      # array and a symbol value becomes a string, as they would in JSON.
      #
      # @param value [Object] the value to convert
      # @param description [String] the name of the item kind, for error messages
      # @param path [String] the location of the value in the item, for error messages
      # @param depth [Integer] the nesting depth of the value
      # @return [Object] the converted value
      # @raise [ArgumentError] if the value is not a JSON-compatible value
      #
      private def normalize_json_value(value, description, path, depth)
        if depth > MAX_PRECONFIGURED_DEPTH
          raise ArgumentError, "a preconfigured #{description} is nested more than #{MAX_PRECONFIGURED_DEPTH} levels deep"
        end

        case value
        when Hash
          value.each_with_object({}) do |(k, v), out|
            unless k.is_a?(String) || k.is_a?(Symbol)
              raise ArgumentError, "a preconfigured #{description} has the key #{k.inspect} at '#{path}', which is not a string or symbol"
            end
            sym = k.to_sym
            if out.key?(sym)
              raise ArgumentError, "a preconfigured #{description} has the key '#{k}' more than once at '#{path}'"
            end
            out[sym] = normalize_json_value(v, description, "#{path}/#{k}", depth + 1)
          end
        when Array, Set
          value.each_with_index.map { |v, i| normalize_json_value(v, description, "#{path}/#{i}", depth + 1) }
        when String
          value.dup
        when Symbol
          value.to_s
        when Integer, true, false, nil
          value
        when Float
          raise ArgumentError, "a preconfigured #{description} has a value at '#{path}' that is not a finite number" unless value.finite?
          value
        else
          raise ArgumentError, "a preconfigured #{description} has a #{value.class} at '#{path}', which is not a JSON value"
        end
      end

      #
      # Returns a builder for creating a data source that can be used with the FDv2 data system
      # as either an initializer or synchronizer.
      #
      # @return [TestDataV2Builder] a builder for a test data source
      #
      def test_data_ds_builder
        TestDataV2Builder.new(self)
      end
    end

    #
    # Builder for TestDataV2 data sources (works for both initializers and synchronizers).
    #
    class TestDataV2Builder
      def initialize(test_data)
        @test_data = test_data
      end

      #
      # Builds the data source.
      #
      # @param sdk_key [String] the SDK key (unused, for interface compatibility)
      # @param config [LaunchDarkly::Config] the SDK configuration (unused, for interface compatibility)
      # @return [LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2] a test data source
      #
      def build(sdk_key, config)
        LaunchDarkly::Impl::Integrations::TestData::TestDataSourceV2.new(@test_data)
      end
    end
  end
end

