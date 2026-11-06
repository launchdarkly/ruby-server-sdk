require "capturing_logger"
require "mock_components"
require "spec_helper"

module LaunchDarkly
  describe "LDClient cached-data warnings" do
    let(:logger) { CapturingLogger.new }
    let(:context) { basic_context }

    # The synchronizer sends no data. The persistent store already holds data, so the client
    # evaluates with cached data.
    def initialized_store
      store = MockFeatureStore.new
      store.init({ LaunchDarkly::Interfaces::DataStore::FEATURES => {}, LaunchDarkly::Interfaces::DataStore::SEGMENTS => {} })
      store
    end

    def cached_data_config
      data_system = silent_data_system_builder
        .data_store(initialized_store, LaunchDarkly::Interfaces::DataSystem::DataStoreMode::READ_WRITE)
        .build
      test_config(logger: logger, data_system_config: data_system)
    end

    def evaluation_warnings(logger)
      logger.output.lines.grep(/Client has not finished initializing; using last known values/)
    end

    def all_flags_state_warnings(logger)
      logger.output.lines.grep(/Called all_flags_state before client initialization; using last known values/)
    end

    it "logs the evaluation warning once per client" do
      with_client(cached_data_config, 0) do |client|
        client.variation("flag", context, false)
        client.variation("flag", context, false)
        client.variation_detail("flag", context, false)
        expect(evaluation_warnings(logger).length).to eq(1)
      end
    end

    # all_flags_state checks LDClient#initialized?, which is true when the store holds data. The
    # stub makes the client report not initialized so the cached-data branch runs.
    it "logs the all_flags_state warning once per client" do
      with_client(cached_data_config, 0) do |client|
        allow(client).to receive(:initialized?).and_return(false)
        client.all_flags_state(context)
        client.all_flags_state(context)
        expect(all_flags_state_warnings(logger).length).to eq(1)
      end
    end

    it "logs the evaluation and all_flags_state warnings independently" do
      with_client(cached_data_config, 0) do |client|
        allow(client).to receive(:initialized?).and_return(false)
        client.variation("flag", context, false)
        client.all_flags_state(context)
        client.variation("flag", context, false)
        client.all_flags_state(context)
        expect(evaluation_warnings(logger).length).to eq(1)
        expect(all_flags_state_warnings(logger).length).to eq(1)
      end
    end

    it "logs the warning again for a new client" do
      with_client(cached_data_config, 0) do |client|
        client.variation("flag", context, false)
      end
      with_client(cached_data_config, 0) do |client|
        client.variation("flag", context, false)
      end
      expect(evaluation_warnings(logger).length).to eq(2)
    end
  end
end
