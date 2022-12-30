require "ldclient-rb"

require "events_test_util"
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
          context = basic_context
          expect(event_processor(client)).to receive(:record_eval_event).with(
            context, 'badkey', nil, nil, 'default', nil, 'default', false, nil, nil
           )
          client.variation("badkey", context, "default")
        end
      end

      it "known flag" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("value").variation_for_all(0))

        context = basic_context
        with_client(test_config(data_source: td)) do |client|
          expect(event_processor(client)).to receive(:record_eval_event).with(
            context, 'flagkey', 1, 0, 'value', nil, 'default', false, nil, nil
          )
          client.variation("flagkey", context, "default")
        end
      end

      it "does not send event, and logs error, if context is nil" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("value").variation_for_all(0))

        logger = double().as_null_object

        with_client(test_config(data_source: td, logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:record_eval_event)
          expect(logger).to receive(:error)
          client.variation("flagkey", nil, "default")
        end
      end

      it "does not send event, and logs error, if context key is nil" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("value").variation_for_all(0))

        logger = double().as_null_object
        keyless_user = { key: nil }

        with_client(test_config(data_source: td, logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:record_eval_event)
          expect(logger).to receive(:error)
          client.variation("flagkey", keyless_user, "default")
        end
      end

      it "sets trackEvents and reason if trackEvents is set for matched rule" do
        td = Integrations::TestData.data_source
        td.use_preconfigured_flag(
          FlagBuilder.new("flagkey").version(100).on(true).variations("value")
            .rule(RuleBuilder.new.variation(0).id("id").track_events(true)
              .clause(Clauses.match_context(basic_context)))
            .build
        )

        context = basic_context
        with_client(test_config(data_source: td)) do |client|
          expect(event_processor(client)).to receive(:record_eval_event).with(
            context, 'flagkey', 100, 0, 'value', LaunchDarkly::EvaluationReason::rule_match(0, 'id'),
            'default', true, nil, nil
          )
          client.variation("flagkey", context, "default")
        end
      end

      it "sets trackEvents and reason if trackEventsFallthrough is set and we fell through" do
        td = Integrations::TestData.data_source
        td.use_preconfigured_flag(
          FlagBuilder.new("flagkey").version(100).on(true).variations("value").fallthrough_variation(0)
            .track_events_fallthrough(true).build
        )

        context = basic_context
        with_client(test_config(data_source: td)) do |client|
          expect(event_processor(client)).to receive(:record_eval_event).with(
            context, 'flagkey', 100, 0, 'value', LaunchDarkly::EvaluationReason::fallthrough,
            'default', true, nil, nil
          )
          client.variation("flagkey", context, "default")
        end
      end
    end

    context "evaluation events - variation_detail" do
      it "unknown flag" do
        with_client(test_config) do |client|
          context = basic_context
          expect(event_processor(client)).to receive(:record_eval_event).with(
            context, 'badkey', nil, nil, 'default',
            LaunchDarkly::EvaluationReason::error(LaunchDarkly::EvaluationReason::ERROR_FLAG_NOT_FOUND),
            'default', false, nil, nil
          )
          client.variation_detail("badkey", context, "default")
        end
      end

      it "known flag" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("value").on(false).off_variation(0))

        context = basic_context
        with_client(test_config(data_source: td)) do |client|
          expect(event_processor(client)).to receive(:record_eval_event).with(
            context, 'flagkey', 1, 0, 'value', LaunchDarkly::EvaluationReason::off,
            'default', false, nil, nil
          )
          client.variation_detail("flagkey", context, "default")
        end
      end

      it "does not send event, and logs error, if context is nil" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("value").on(false).off_variation(0))

        logger = double().as_null_object

        with_client(test_config(data_source: td, logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:record_eval_event)
          expect(logger).to receive(:error)
          client.variation_detail("flagkey", nil, "default")
        end
      end

      it "does not send event, and logs warning, if context key is nil" do
        td = Integrations::TestData.data_source
        td.update(td.flag("flagkey").variations("value").on(false).off_variation(0))

        logger = double().as_null_object

        with_client(test_config(data_source: td, logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:record_eval_event)
          expect(logger).to receive(:error)
          client.variation_detail("flagkey", { key: nil }, "default")
        end
      end
    end

    context "identify" do
      it "queues up an identify event" do
        context = basic_context
        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:record_identify_event).with(context)
          client.identify(context)
        end
      end

      it "does not send event, and logs warning, if context is nil" do
        logger = double().as_null_object

        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:record_identify_event)
          expect(logger).to receive(:warn)
          client.identify(nil)
        end
      end

      it "does not send event, and logs warning, if context key is blank" do
        logger = double().as_null_object

        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:record_identify_event)
          expect(logger).to receive(:warn)
          client.identify({ key: "" })
        end
      end
    end

    context "track" do
      it "queues up an custom event" do
        context = basic_context
        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:record_custom_event).with(
            context, 'custom_event_name', 42, nil
          )
          client.track("custom_event_name", context, 42)
        end
      end

      it "can include a metric value" do
        context = basic_context
        with_client(test_config) do |client|
          expect(event_processor(client)).to receive(:record_custom_event).with(
            context, 'custom_event_name', nil, 1.5
          )
          client.track("custom_event_name", context, nil, 1.5)
        end
      end

      it "does not send event, and logs a warning, if context is nil" do
        logger = double().as_null_object

        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:record_custom_event)
          expect(logger).to receive(:warn)
          client.track("custom_event_name", nil, nil)
        end
      end

      it "does not send event, and logs warning, if context key is nil" do
        logger = double().as_null_object

        with_client(test_config(logger: logger)) do |client|
          expect(event_processor(client)).not_to receive(:record_custom_event)
          expect(logger).to receive(:warn)
          client.track("custom_event_name", { key: nil }, nil)
        end
      end
    end
  end
end
