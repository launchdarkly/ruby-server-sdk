module LaunchDarkly
  module Impl
    #
    # Simple helper class for returning formatted data.
    #
    # The variation methods make use of the new hook support. Those methods all need to return an evaluation detail, and
    # some other unstructured bit of data.
    #
    class EvaluationWithHookResult
      #
      # Return the evaluation detail that was generated as part of the evaluation.
      #
      # @return [LaunchDarkly::EvaluationDetail]
      #
      attr_reader :evaluation_detail

      #
      # All purpose container for additional return values from the wrapping method
      #
      # @return [any]
      #
      attr_reader :results

      #
      # @param evaluation_detail [LaunchDarkly::EvaluationDetail]
      # @param results [any]
      #
      def initialize(evaluation_detail, results = nil)
        @evaluation_detail = evaluation_detail
        @results = results
      end
    end
  end
end
