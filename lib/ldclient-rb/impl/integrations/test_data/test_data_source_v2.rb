require 'concurrent/atomics'
require 'ldclient-rb/impl/data_system'
require 'ldclient-rb/interfaces/data_system'
require 'ldclient-rb/util'
require 'thread'

module LaunchDarkly
  module Impl
    module Integrations
      module TestData
        #
        # Internal implementation of both Initializer and Synchronizer protocols for TestDataV2.
        #
        # This component bridges the test data management in TestDataV2 with the FDv2 protocol
        # interfaces. Each instance implements both Initializer and Synchronizer protocols
        # and receives change notifications for dynamic updates.
        #
        class TestDataSourceV2
          include LaunchDarkly::Interfaces::DataSystem::Initializer
          include LaunchDarkly::Interfaces::DataSystem::Synchronizer

          # @api private
          #
          # @param test_data [LaunchDarkly::Integrations::TestDataV2] the test data instance
          #
          def initialize(test_data)
            @test_data = test_data
            @closed = false
            @update_queue = Queue.new
            @lock = Mutex.new

            # Always register for change notifications
            @test_data.add_instance(self)
          end

          #
          # Return the name of this data source.
          #
          # @return [String]
          #
          def name
            'TestDataV2'
          end

          #
          # Implementation of the Initializer.fetch method.
          #
          # Returns the current test data as a Basis for initial data loading.
          #
          # @param selector_store [LaunchDarkly::Interfaces::DataSystem::SelectorStore] Provides the Selector (unused for test data)
          # @return [LaunchDarkly::Result] A Result containing either a Basis or an error message
          #
          def fetch(selector_store)
            begin
              @lock.synchronize do
                if @closed
                  return LaunchDarkly::Result.fail('TestDataV2 source has been closed')
                end

                # Get all current flags from test data
                init_data = @test_data.make_init_data
                version = @test_data.get_version

                # Build a full transfer changeset
                builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
                builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_FULL)

                # Add all flags to the changeset
                init_data.each do |key, flag_data|
                  builder.add_put(
                    LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                    key,
                    flag_data[:version] || 1,
                    flag_data
                  )
                end

                # Create selector for this version
                selector = LaunchDarkly::Interfaces::DataSystem::Selector.new_selector(version.to_s, version)
                change_set = builder.finish(selector)

                basis = LaunchDarkly::Interfaces::DataSystem::Basis.new(change_set: change_set, persist: false, environment_id: nil)

                LaunchDarkly::Result.success(basis)
              end
            rescue => e
              LaunchDarkly::Result.fail("Error fetching test data: #{e.message}", e)
            end
          end

          #
          # Implementation of the Synchronizer.sync method.
          #
          # Yields updates as test data changes occur.
          #
          # @param selector_store [LaunchDarkly::Interfaces::DataSystem::SelectorStore] Provides the Selector (unused for test data)
          # @yield [LaunchDarkly::Interfaces::DataSystem::Update] Yields Update objects as synchronization progresses
          # @return [void]
          #
          def sync(selector_store)
            # First yield initial data
            initial_result = fetch(selector_store)
            unless initial_result.success?
              yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
                error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                  LaunchDarkly::Interfaces::DataSource::ErrorInfo::STORE_ERROR,
                  0,
                  initial_result.error,
                  Time.now
                )
              )
              return
            end

            # Yield the initial successful state
            yield LaunchDarkly::Interfaces::DataSystem::Update.new(
              state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
              change_set: initial_result.value.change_set
            )

            # Continue yielding updates as they arrive
            until @closed
              begin
                # stop() will push nil to the queue to wake us up when shutting down
                update = @update_queue.pop

                # Handle nil sentinel for shutdown
                break if update.nil?

                # Yield the actual update
                yield update
              rescue => e
                yield LaunchDarkly::Interfaces::DataSystem::Update.new(
                  state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
                  error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                    LaunchDarkly::Interfaces::DataSource::ErrorInfo::UNKNOWN,
                    0,
                    "Error in test data synchronizer: #{e.message}",
                    Time.now
                  )
                )
                break
              end
            end
          end

          #
          # Stop the data source and clean up resources
          #
          # @return [void]
          #
          def stop
            @lock.synchronize do
              return if @closed
              @closed = true
            end

            @test_data.closed_instance(self)
            # Signal shutdown to sync generator
            @update_queue.push(nil)
          end

          #
          # Called by TestDataV2 when a flag is updated.
          #
          # This method converts the flag update into an FDv2 changeset and
          # queues it for delivery through the sync() generator.
          #
          # @param flag_data [Hash] the flag data
          # @return [void]
          #
          def upsert_flag(flag_data)
            @lock.synchronize do
              return if @closed

              begin
                version = @test_data.get_version

                # Build a changes transfer changeset
                builder = LaunchDarkly::Interfaces::DataSystem::ChangeSetBuilder.new
                builder.start(LaunchDarkly::Interfaces::DataSystem::IntentCode::TRANSFER_CHANGES)

                # Add the updated flag
                builder.add_put(
                  LaunchDarkly::Interfaces::DataSystem::ObjectKind::FLAG,
                  flag_data[:key],
                  flag_data[:version] || 1,
                  flag_data
                )

                # Create selector for this version
                selector = LaunchDarkly::Interfaces::DataSystem::Selector.new_selector(version.to_s, version)
                change_set = builder.finish(selector)

                # Queue the update
                update = LaunchDarkly::Interfaces::DataSystem::Update.new(
                  state: LaunchDarkly::Interfaces::DataSource::Status::VALID,
                  change_set: change_set
                )

                @update_queue.push(update)
              rescue => e
                # Queue an error update
                error_update = LaunchDarkly::Interfaces::DataSystem::Update.new(
                  state: LaunchDarkly::Interfaces::DataSource::Status::OFF,
                  error: LaunchDarkly::Interfaces::DataSource::ErrorInfo.new(
                    LaunchDarkly::Interfaces::DataSource::ErrorInfo::STORE_ERROR,
                    0,
                    "Error processing flag update: #{e.message}",
                    Time.now
                  )
                )
                @update_queue.push(error_update)
              end
            end
          end
        end
      end
    end
  end
end

