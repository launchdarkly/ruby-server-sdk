# frozen_string_literal: true

require "concurrent"
require "ldclient-rb/config"
require "ldclient-rb/impl/data_system"
require "ldclient-rb/impl/data_store/store"
require "ldclient-rb/impl/data_store/feature_store_client_wrapper"
require "ldclient-rb/impl/data_source/status_provider"
require "ldclient-rb/impl/data_store/status_provider"
require "ldclient-rb/impl/broadcaster"
require "ldclient-rb/impl/repeating_task"
require "ldclient-rb/interfaces/data_system"

module LaunchDarkly
  module Impl
    module DataSystem
      #
      # Represents the possible outcomes from consuming synchronizer results.
      #
      # Used by {FDv2#consume_synchronizer_results} to indicate what action the
      # synchronizer loop should take next.
      #
      module SyncResult
        # Temporarily move to the next synchronizer in the list.
        # The current synchronizer remains available for future recovery.
        FALLBACK = :fallback

        # Return to the first synchronizer in the list.
        # Used when recovery conditions are met on a fallback synchronizer.
        RECOVER = :recover

        # Permanently remove the current synchronizer from the list.
        # Used for unrecoverable failures (OFF state, exceptions).
        REMOVE = :remove

        # Switch to the FDv1 protocol fallback.
        # Replaces the synchronizer list with the FDv1 fallback synchronizer.
        FDV1 = :fdv1
      end

      # FDv2 is an implementation of the DataSystem interface that uses the Flag Delivery V2 protocol
      # for obtaining and keeping data up-to-date. Additionally, it operates with an optional persistent
      # store in read-only or read/write mode.
      class FDv2
        include LaunchDarkly::Impl::DataSystem

        # Initialize a new FDv2 data system.
        #
        # @param sdk_key [String] The SDK key
        # @param config [LaunchDarkly::Config] Configuration for initializers and synchronizers
        # @param data_system_config [LaunchDarkly::DataSystemConfig] FDv2 data system configuration
        def initialize(sdk_key, config, data_system_config)
          @sdk_key = sdk_key
          @config = config
          @data_system_config = data_system_config
          @logger = config.logger
          @synchronizer_builders = data_system_config.synchronizers || []
          @fdv1_fallback_synchronizer_builder = data_system_config.fdv1_fallback_synchronizer
          @disabled = @config.offline?

          # Diagnostic accumulator provided by client for streaming metrics
          @diagnostic_accumulator = nil

          # Shared executor for all broadcasters
          @shared_executor = Concurrent::SingleThreadExecutor.new

          # Set up event listeners
          @flag_change_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, @logger)
          @change_set_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, @logger)
          @data_source_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, @logger)
          @data_store_broadcaster = LaunchDarkly::Impl::Broadcaster.new(@shared_executor, @logger)

          recovery_listener = Object.new
          recovery_listener.define_singleton_method(:update) do |data_store_status|
            persistent_store_outage_recovery(data_store_status)
          end
          @data_store_broadcaster.add_listener(recovery_listener)

          # Create the store
          @store = LaunchDarkly::Impl::DataStore::Store.new(@flag_change_broadcaster, @change_set_broadcaster, @logger)

          # Status providers
          @data_source_status_provider = LaunchDarkly::Impl::DataSource::StatusProviderV2.new(
            @data_source_broadcaster
          )
          @data_store_status_provider = LaunchDarkly::Impl::DataStore::StatusProviderV2.new(nil, @data_store_broadcaster)

          # Configure persistent store if provided
          if @data_system_config.data_store
            @data_store_status_provider = LaunchDarkly::Impl::DataStore::StatusProviderV2.new(
              @data_system_config.data_store,
              @data_store_broadcaster
            )
            writable = @data_system_config.data_store_mode == :read_write
            wrapper = LaunchDarkly::Impl::DataStore::FeatureStoreClientWrapperV2.new(
              @data_system_config.data_store,
              @data_store_status_provider,
              @logger
            )
            @store.with_persistence(wrapper, writable, @data_store_status_provider)
          end

          # Threading
          @stop_event = Concurrent::Event.new
          @ready_event = Concurrent::Event.new
          @lock = Mutex.new
          @active_synchronizer = nil
          @threads = []

          # Track configuration
          @configured_with_data_sources = (@data_system_config.initializers && !@data_system_config.initializers.empty?) ||
            !@synchronizer_builders.empty?
        end

        # (see DataSystem#start)
        def start
          if @disabled
            @logger.warn { "[LDClient] Data system is disabled, SDK will return application-defined default values" }
            @ready_event.set
            return @ready_event
          end

          @stop_event.reset
          @ready_event.reset

          # Start the main coordination thread
          main_thread = Thread.new { run_main_loop }
          main_thread.name = "FDv2-main"
          @threads << main_thread

          @ready_event
        end

        # (see DataSystem#stop)
        def stop
          @stop_event.set

          @lock.synchronize do
            if @active_synchronizer
              begin
                @active_synchronizer.stop
              rescue => e
                @logger.error { "[LDClient] Error stopping active data source: #{e.message}" }
              end
            end
          end

          # Wait for all threads to complete
          @threads.each do |thread|
            next unless thread.alive?

            thread.join(5.0) # 5 second timeout
            @logger.warn { "[LDClient] Thread #{thread.name} did not terminate in time" } if thread.alive?
          end

          # Close the store
          @store.close

          # Shutdown the shared executor
          @shared_executor.shutdown
        end

        # (see DataSystem#set_diagnostic_accumulator)
        def set_diagnostic_accumulator(diagnostic_accumulator)
          @diagnostic_accumulator = diagnostic_accumulator
        end

        # (see DataSystem#store)
        def store
          @store.get_active_store
        end

        # (see DataSystem#data_source_status_provider)
        def data_source_status_provider
          @data_source_status_provider
        end

        # (see DataSystem#data_store_status_provider)
        def data_store_status_provider
          @data_store_status_provider
        end

        # (see DataSystem#flag_change_broadcaster)
        def flag_change_broadcaster
          @flag_change_broadcaster
        end

        # (see DataSystem#data_availability)
        def data_availability
          return DataAvailability::REFRESHED if @store.selector.defined?
          return DataAvailability::CACHED if !@configured_with_data_sources || @store.initialized?

          DataAvailability::DEFAULTS
        end

        # (see DataSystem#target_availability)
        def target_availability
          return DataAvailability::REFRESHED if @configured_with_data_sources

          DataAvailability::CACHED
        end

        private

        #
        # Main coordination loop that manages initializers and synchronizers.
        #
        # @return [void]
        #
        def run_main_loop
          begin
            @data_source_status_provider.update_status(
              LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING,
              nil
            )

            # Run initializers first
            run_initializers

            # Run synchronizers
            run_synchronizers
          rescue => e
            @logger.error { "[LDClient] Error in FDv2 main loop: #{e.message}" }
            @ready_event.set
          end
        end

        #
        # Run initializers to get initial data.
        #
        # @return [void]
        #
        def run_initializers
          return unless @data_system_config.initializers

          @data_system_config.initializers.each do |initializer_builder|
            return if @stop_event.set?

            begin
              initializer = initializer_builder.build(@sdk_key, @config)
              @logger.info { "[LDClient] Attempting to initialize via #{initializer.name}" }

              basis_result = initializer.fetch(@store)

              if basis_result.success?
                basis = basis_result.value
                @logger.info { "[LDClient] Initialized via #{initializer.name}" }

                # Apply the basis to the store
                @store.apply(basis.change_set, basis.persist)

                # Set ready event if and only if a selector is defined for the changeset
                if basis.change_set.selector && basis.change_set.selector.defined?
                  @ready_event.set
                  return
                end
              else
                @logger.warn { "[LDClient] Initializer #{initializer.name} failed: #{basis_result.error}" }
              end
            rescue => e
              @logger.error { "[LDClient] Initializer failed with exception: #{e.message}" }
            end
          end
        end

        #
        # Run synchronizers to keep data up-to-date.
        #
        # @return [void]
        #
        def run_synchronizers
          # If no synchronizers configured, just set ready and return
          if @synchronizer_builders.empty?
            @ready_event.set
            return
          end

          # Start synchronizer loop in a separate thread
          sync_thread = Thread.new { synchronizer_loop }
          sync_thread.name = "FDv2-synchronizers"
          @threads << sync_thread
        end

        #
        # Synchronizer loop that manages synchronizers and fallbacks.
        #
        # @return [void]
        #
        def synchronizer_loop
          # Track the current index in the synchronizer array
          current_index = 0

          begin
            while !@stop_event.set? && current_index < @synchronizer_builders.length
              synchronizer_builder = @synchronizer_builders[current_index]
              is_primary = current_index == 0

              begin
                @lock.synchronize do
                  sync = synchronizer_builder.build(@sdk_key, @config)
                  if sync.respond_to?(:set_diagnostic_accumulator) && @diagnostic_accumulator
                    sync.set_diagnostic_accumulator(@diagnostic_accumulator)
                  end
                  @active_synchronizer = sync
                end

                @logger.info { "[LDClient] Synchronizer[#{current_index}] #{@active_synchronizer.name} is starting" }

                sync_result = consume_synchronizer_results(@active_synchronizer, check_recovery: !is_primary)

                break if @stop_event.set?

                case sync_result
                when SyncResult::FDV1
                  if @fdv1_fallback_synchronizer_builder
                    @synchronizer_builders = [@fdv1_fallback_synchronizer_builder]
                    current_index = 0
                    next
                  end
                  # No FDv1 fallback configured, treat as regular fallback
                  current_index += 1
                when SyncResult::RECOVER
                  @logger.info { "[LDClient] Recovery condition met, returning to primary synchronizer" }
                  current_index = 0
                when SyncResult::REMOVE
                  @logger.info { "[LDClient] Removing synchronizer from list due to permanent failure" }
                  @synchronizer_builders.delete_at(current_index)
                else
                  @logger.info { "[LDClient] Fallback condition met" }
                  current_index += 1
                end

                current_index = 0 if current_index >= @synchronizer_builders.length

                if @synchronizer_builders.length == 0
                  @logger.warn { "[LDClient] No more synchronizers available" }
                  @data_source_status_provider.update_status(
                    LaunchDarkly::Interfaces::DataSource::Status::OFF,
                    @data_source_status_provider.status.last_error
                  )
                  break
                end
              rescue => e
                @logger.error { "[LDClient] Failed to build synchronizer: #{e.message}" }
                break
              end
            end
          rescue => e
            @logger.error { "[LDClient] Error in synchronizer loop: #{e.message}" }
          ensure
            # Ensure we always set the ready event when exiting
            @ready_event.set
            @lock.synchronize do
              @active_synchronizer&.stop
              @active_synchronizer = nil
            end
          end
        end

        #
        # Consume results from a synchronizer until a condition is met or it fails.
        #
        # @param synchronizer [Object] The synchronizer
        # @param check_recovery [Boolean] Whether to check recovery condition (healthy too long)
        # @return [Symbol] One of {SyncResult::FALLBACK}, {SyncResult::RECOVER}, {SyncResult::REMOVE}, or {SyncResult::FDV1}
        #
        def consume_synchronizer_results(synchronizer, check_recovery: false)
          action_queue = Queue.new
          timer = LaunchDarkly::Impl::RepeatingTask.new(10, 10, -> { action_queue.push("check") }, @logger, "FDv2-sync-cond-timer")

          # Start reader thread
          sync_reader = Thread.new do
            begin
              synchronizer.sync(@store) do |update|
                action_queue.push(update)
              end
            ensure
              action_queue.push("quit")
            end
          end
          sync_reader.name = "FDv2-sync-reader"

          begin
            timer.start

            loop do
              update = action_queue.pop

              if update.is_a?(String)
                break if update == "quit"

                if update == "check"
                  # Check condition periodically
                  current_status = @data_source_status_provider.status
                  return SyncResult::RECOVER if check_recovery && recovery_condition(current_status)
                  return SyncResult::FALLBACK if fallback_condition(current_status)
                end
                next
              end

              @logger.info { "[LDClient] Synchronizer #{synchronizer.name} update: #{update.state}" }
              return SyncResult::FALLBACK if @stop_event.set?

              # Handle the update
              @store.apply(update.change_set, true) if update.change_set

              # Set ready event on valid update
              @ready_event.set if update.state == LaunchDarkly::Interfaces::DataSource::Status::VALID

              # Update status
              @data_source_status_provider.update_status(update.state, update.error)

              return SyncResult::FDV1 if update.revert_to_fdv1

              return SyncResult::REMOVE if update.state == LaunchDarkly::Interfaces::DataSource::Status::OFF
            end
          rescue => e
            @logger.error { "[LDClient] Error consuming synchronizer results: #{e.message}" }
            return SyncResult::REMOVE
          ensure
            synchronizer.stop
            timer.stop
            sync_reader.join(0.5) if sync_reader.alive?
          end

          SyncResult::REMOVE
        end

        #
        # Determine if we should fallback to the next synchronizer.
        #
        # @param status [LaunchDarkly::Interfaces::DataSource::Status] Current data source status
        # @return [Boolean] true if fallback condition is met
        #
        def fallback_condition(status)
          interrupted_at_runtime = status.state == LaunchDarkly::Interfaces::DataSource::Status::INTERRUPTED &&
            Time.now - status.state_since > 60  # 1 minute
          cannot_initialize = status.state == LaunchDarkly::Interfaces::DataSource::Status::INITIALIZING &&
            Time.now - status.state_since > 10  # 10 seconds

          interrupted_at_runtime || cannot_initialize
        end

        #
        # Determine if we should recover to the primary synchronizer.
        #
        # @param status [LaunchDarkly::Interfaces::DataSource::Status] Current data source status
        # @return [Boolean] true if recovery condition is met (healthy for too long)
        #
        def recovery_condition(status)
          status.state == LaunchDarkly::Interfaces::DataSource::Status::VALID &&
            Time.now - status.state_since > 300  # 5 minutes
        end

        #
        # Monitor the data store status. If the store comes online and
        # potentially has stale data, we should write our known state to it.
        #
        # @param data_store_status [LaunchDarkly::Interfaces::DataStore::Status] The store status
        # @return [void]
        #
        def persistent_store_outage_recovery(data_store_status)
          return unless data_store_status.available
          return unless data_store_status.stale

          err = @store.commit
          @logger.error { "[LDClient] Failed to reinitialize data store: #{err.message}" } if err
        end
      end
    end
  end
end
