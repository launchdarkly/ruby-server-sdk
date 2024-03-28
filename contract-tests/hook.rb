require 'ldclient-rb'

class Hook
  include LaunchDarkly::Interfaces::Hooks::Hook

  #
  # @param name [String]
  # @param callback_uri [String]
  # @param data [Hash]
  #
  def initialize(name, callback_uri, data)
    @metadata = LaunchDarkly::Interfaces::Hooks::Metadata.new(name)
    @callback_uri = callback_uri
    @data = data
    @context_filter = LaunchDarkly::Impl::ContextFilter.new(false, [])
  end

  def metadata
    @metadata
  end

  #
  # @param evaluation_series_context [LaunchDarkly::Interfaces::Hooks::EvaluationSeriesContext]
  # @param data [Hash]
  #
  def before_evaluation(evaluation_series_context, data)
    payload = {
      evaluationSeriesContext: {
        flagKey: evaluation_series_context.key,
        context: @context_filter.filter(evaluation_series_context.context),
        defaultValue: evaluation_series_context.default_value,
        method: evaluation_series_context.method,
      },
      evaluationSeriesData: data,
      stage: 'beforeEvaluation',
    }
    result = HTTP.post(@callback_uri, json: payload)

    (data || {}).merge(@data[:beforeEvaluation] || {})
  end


  #
  # @param evaluation_series_context [LaunchDarkly::Interfaces::Hooks::EvaluationSeriesContext]
  # @param data [Hash]
  # @param detail [LaunchDarkly::EvaluationDetail]
  #
  def after_evaluation(evaluation_series_context, data, detail)
    payload = {
      evaluationSeriesContext: {
        flagKey: evaluation_series_context.key,
        context: @context_filter.filter(evaluation_series_context.context),
        defaultValue: evaluation_series_context.default_value,
        method: evaluation_series_context.method,
      },
      evaluationSeriesData: data,
      evaluationDetail: {
        value: detail.value,
        variationIndex: detail.variation_index,
        reason: detail.reason,
      },
      stage: 'afterEvaluation',
    }
    HTTP.post(@callback_uri, json: payload)

    (data || {}).merge(@data[:afterEvaluation] || {})
  end
end
