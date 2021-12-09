require 'concurrent/atomics'
require 'ldclient-rb/interfaces'

module LaunchDarkly
  module Impl
    module Integrations
      module TestData
        # @private
        class TestDataSource
          include LaunchDarkly::Interfaces::DataSource

          def initialize(feature_store, test_data)
            @feature_store = feature_store
            @test_data = test_data
          end

          def initialized?
            true
          end

          def start
            ready = Concurrent::Event.new
            ready.set
            init_data = @test_data.make_init_data
            @feature_store.init(init_data)
            ready
          end

          def stop
            @test_data.closed_instance(self)
          end

          def upsert(kind, item)
            @feature_store.upsert(kind, item)
          end
        end
      end
    end
  end
end
