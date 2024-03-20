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
  # @param hook_context [LaunchDarkly::Interfaces::Hooks::EvaluationContext]
  # @param data [Hash]
  #
  def before_evaluation(hook_context, data)
    payload = {
      evaluationHookContext: {
        flagKey: hook_context.key,
        context: @context_filter.filter(hook_context.context),
        defaultValue: hook_context.default_value,
        method: hook_context.method,
      },
      evaluationHookData: data,
      stage: 'beforeEvaluation',
    }
    result = HTTP.post(@callback_uri, json: payload)

    (data || {}).merge(@data[:beforeEvaluation] || {})
  end


  #
  # @param hook_context [LaunchDarkly::Interfaces::Hooks::EvaluationContext]
  # @param data [Hash]
  # @param detail [LaunchDarkly::EvaluationDetail]
  #
  def after_evaluation(hook_context, data, detail)
    payload = {
      evaluationHookContext: {
        flagKey: hook_context.key,
        context: @context_filter.filter(hook_context.context),
        defaultValue: hook_context.default_value,
        method: hook_context.method,
      },
      evaluationHookData: data,
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
