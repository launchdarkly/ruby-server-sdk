require "ldclient-rb"

require "mock_components"
require "model_builders"
require "spec_helper"

module LaunchDarkly
  describe "LDClient events tests" do
    def event_processor(client)
      client.instance_variable_get(:@event_processor)
    end

    it 'uses NullEventProcessor if send_events is false' do
      with_client(test_config(send_events: false)) do |client|
        expect(event_processor(client)).to be_a(LaunchDarkly::NullEventProcessor)
      end
    end
  
    context "evaluation events - variation" do
      it "unknown flag" do
        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "feature", key: "badkey", user: basic_user, value: "default", default: "default"
          ))
          client.variation("badkey", basic_user, "default")
        end
      end

      it "known flag" do
        flag = FlagBuilder.new("flagkey").version(100).off_with_value("value").
          track_events(true).debug_events_until_date(1000).build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)
        
        with_client(test_config(feature_store: store)) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "feature",
            key: flag[:key],
            version: flag[:version],
            user: basic_user,
            variation: 0,
            value: "value",
            default: "default",
            trackEvents: true,
            debugEventsUntilDate: 1000
          ))
          client.variation(flag[:key], basic_user, "default")
        end
      end

      it "does not send event, and logs error, if user is nil" do
        flag = FlagBuilder.new("flagkey").version(100).off_with_value("value").build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)
        logger = double().as_null_object
        
        with_client(test_config(feature_store: store, logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:error)
          client.variation(flag[:key], nil, "default")
        end
      end

      it "does not send event, and logs warning, if user key is nil" do
        flag = FlagBuilder.new("flagkey").version(100).off_with_value("value").build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)
        logger = double().as_null_object
        keyless_user = { key: nil }

        with_client(test_config(feature_store: store, logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:warn)
          client.variation(flag[:key], keyless_user, "default")
        end
      end

      it "sets trackEvents and reason if trackEvents is set for matched rule" do
        flag = FlagBuilder.new("flagkey").version(100).on(true).variations("value").
          rule(RuleBuilder.new.variation(0).id("id").track_events(true).
            clause(Clauses.match_user(basic_user))).
          build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)

        with_client(test_config(feature_store: store)) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "feature",
            key: flag[:key],
            version: flag[:version],
            user: basic_user,
            variation: 0,
            value: "value",
            default: "default",
            trackEvents: true,
            reason: LaunchDarkly::EvaluationReason::rule_match(0, 'id')
          ))
          client.variation(flag[:key], basic_user, "default")
        end
      end

      it "sets trackEvents and reason if trackEventsFallthrough is set and we fell through" do
        flag = FlagBuilder.new("flagkey").version(100).on(true).variations("value").fallthrough_variation(0).
          track_events_fallthrough(true).build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)

        with_client(test_config(feature_store: store)) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "feature",
            key: flag[:key],
            version: flag[:version],
            user: basic_user,
            variation: 0,
            value: "value",
            default: "default",
            trackEvents: true,
            reason: LaunchDarkly::EvaluationReason::fallthrough
          ))
          client.variation(flag[:key], basic_user, "default")
        end
      end
    end

    context "evaluation events - variation_detail" do
      it "unknown flag" do
        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "feature", key: "badkey", user: basic_user, value: "default", default: "default",
            reason: LaunchDarkly::EvaluationReason::error(LaunchDarkly::EvaluationReason::ERROR_FLAG_NOT_FOUND)
          ))
          client.variation_detail("badkey", basic_user, "default")
        end
      end

      it "known flag" do
        flag = FlagBuilder.new("flagkey").version(100).off_with_value("value").
          track_events(true).debug_events_until_date(1000).build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)
        
        with_client(test_config(feature_store: store)) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "feature",
            key: flag[:key],
            version: flag[:version],
            user: basic_user,
            variation: 0,
            value: "value",
            default: "default",
            trackEvents: true,
            debugEventsUntilDate: 1000,
            reason: LaunchDarkly::EvaluationReason::off
          ))
          client.variation_detail(flag[:key], basic_user, "default")
        end
      end

      it "does not send event, and logs error, if user is nil" do
        flag = FlagBuilder.new("flagkey").version(100).off_with_value("value").build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)
        logger = double().as_null_object
        
        with_client(test_config(feature_store: store, logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:error)
          client.variation_detail(flag[:key], nil, "default")
        end
      end

      it "does not send event, and logs warning, if user key is nil" do
        flag = FlagBuilder.new("flagkey").version(100).off_with_value("value").build
        store = InMemoryFeatureStore.new
        store.upsert(FEATURES, flag)
        logger = double().as_null_object

        with_client(test_config(feature_store: store, logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:warn)
          client.variation_detail(flag[:key], { key: nil }, "default")
        end
      end
    end

    context "identify" do 
      it "queues up an identify event" do
        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "identify", key: basic_user[:key], user: basic_user))
          client.identify(basic_user)
        end
      end

      it "does not send event, and logs warning, if user is nil" do
        logger = double().as_null_object

        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:warn)
          client.identify(nil)
        end
      end

      it "does not send event, and logs warning, if user key is nil" do
        logger = double().as_null_object
        
        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:warn)
          client.identify({ key: nil })
        end
      end
    end

    context "track" do 
      it "queues up an custom event" do
        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "custom", key: "custom_event_name", user: basic_user, data: 42))
          client.track("custom_event_name", basic_user, 42)
        end
      end

      it "can include a metric value" do
        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "custom", key: "custom_event_name", user: basic_user, metricValue: 1.5))
          client.track("custom_event_name", basic_user, nil, 1.5)
        end
      end

      it "includes contextKind with anonymous user" do
        anon_user = { key: 'user-key', anonymous: true }

        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "custom", key: "custom_event_name", user: anon_user, metricValue: 2.2, contextKind: "anonymousUser"))
          client.track("custom_event_name", anon_user, nil, 2.2)
        end
      end

      it "sanitizes the user in the event" do
        numeric_key_user = { key: 33 }
        sanitized_user = { key: "33" }

        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(user: sanitized_user))
          client.track("custom_event_name", numeric_key_user, nil)
        end
      end

      it "does not send event, and logs a warning, if user is nil" do
        logger = double().as_null_object

        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:warn)
          client.track("custom_event_name", nil, nil)
        end
      end

      it "does not send event, and logs warning, if user key is nil" do
        logger = double().as_null_object

        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:warn)
          client.track("custom_event_name", { key: nil }, nil)
        end
      end
    end

    context "alias" do
      it "queues up an alias event" do
        anon_user = { key: "user-key", anonymous: true }
        
        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:add_event).with(hash_including(
            kind: "alias", key: basic_user[:key], contextKind: "user", previousKey: anon_user[:key], previousContextKind: "anonymousUser"))
          client.alias(basic_user, anon_user)
        end
      end

      it "does not send event, and logs warning, if user is nil" do
        logger = double().as_null_object

        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:warn)
          client.alias(nil, nil)
        end
      end

      it "does not send event, and logs warning, if user key is nil" do
        logger = double().as_null_object

        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:add_event)
          expect(logger).to receive(:warn)
          client.alias({ key: nil }, { key: nil })
        end
      end
    end
  end
end
