module LaunchDarkly
  module Interfaces
    module Hooks
      #
      # Mixin for extending SDK functionality via hooks.
      #
      # All provided hook implementations **MUST** include this mixin. Hooks without this mixin will be ignored.
      #
      # This mixin includes default implementations for all hook handlers. This allows LaunchDarkly to expand the list
      # of hook handlers without breaking customer integrations.
      #
      module Hook
        #
        # Get metadata about the hook implementation.
        #
        # @return [Metadata]
        #
        def metadata
          Metadata.new('UNDEFINED')
        end

        #
        # The before method is called during the execution of a variation method before the flag value has been
        # determined. The method is executed synchronously.
        #
        # @param evaluation_series_context [EvaluationSeriesContext] Contains information about the evaluation being
        # performed. This is not mutable.
        # @param data [Hash] A record associated with each stage of hook invocations. Each stage is called with the data
        # of the previous stage for a series. The input record should not be modified.
        # @return [Hash] Data to use when executing the next state of the hook in the evaluation series.
        #
        def before_evaluation(evaluation_series_context, data)
          data
        end

        #
        # The after method is called during the execution of the variation method after the flag value has been
        # determined. The method is executed synchronously.
        #
        # @param evaluation_series_context [EvaluationSeriesContext] Contains read-only information about the evaluation
        # being performed.
        # @param data [Hash] A record associated with each stage of hook invocations. Each stage is called with the data
        # of the previous stage for a series.
        # @param detail [LaunchDarkly::EvaluationDetail] The result of the evaluation. This value should not be
        # modified.
        # @return [Hash] Data to use when executing the next state of the hook in the evaluation series.
        #
        def after_evaluation(evaluation_series_context, data, detail)
          data
        end
      end

      #
      # Metadata data class used for annotating hook implementations.
      #
      class Metadata
        attr_reader :name

        def initialize(name)
          @name = name
        end
      end

      #
      # Contextual information that will be provided to handlers during evaluation series.
      #
      class EvaluationSeriesContext
        attr_reader :key
        attr_reader :context
        attr_reader :default_value
        attr_reader :method

        #
        # @param key [String]
        # @param context [LaunchDarkly::LDContext]
        # @param default_value [any]
        # @param method [Symbol]
        #
        def initialize(key, context, default_value, method)
          @key = key
          @context = context
          @default_value = default_value
          @method = method
        end
      end
    end
  end
end
