module LaunchDarkly
  module Impl
    # Encapsulates the logic for percentage rollouts.
    module EvaluatorBucketing
      # Applies either a fixed variation or a rollout for a rule (or the fallthrough rule).
      #
      # @param flag [Object] the feature flag
      # @param vr [LaunchDarkly::Impl::Model::VariationOrRollout] the variation/rollout properties
      # @param context [LaunchDarkly::LDContext] the context properties
      # @return [Array<[Number, nil], Boolean>] the variation index, or nil if there is an error
      # @raise [InvalidReferenceException]
      def self.variation_index_for_context(flag, vr, context)
        variation = vr.variation
        return variation, false unless variation.nil? # fixed variation
        rollout = vr.rollout
        return nil, false if rollout.nil?
        variations = rollout.variations
        if !variations.nil? && variations.length > 0 # percentage rollout
          rollout_is_experiment = rollout.is_experiment
          bucket_by = rollout_is_experiment ? nil : rollout.bucket_by
          bucket_by = 'key' if bucket_by.nil?

          seed = rollout.seed
          bucket = bucket_context(context, rollout.context_kind, flag.key, bucket_by, flag.salt, seed) # may not be present
          in_experiment = rollout_is_experiment && !bucket.nil?
          sum = 0
          variations.each do |variate|
            sum += variate.weight.to_f / 100000.0
            if bucket.nil? || bucket < sum
              return variate.variation, in_experiment && !variate.untracked
            end
          end
          # The context's bucket value was greater than or equal to the end of the last bucket. This could happen due
          # to a rounding error, or due to the fact that we are scaling to 100000 rather than 99999, or the flag
          # data could contain buckets that don't actually add up to 100000. Rather than returning an error in
          # this case (or changing the scaling, which would potentially change the results for *all* contexts), we
          # will simply put the context in the last bucket.
          last_variation = variations[-1]
          [last_variation.variation, in_experiment && !last_variation.untracked]
        else # the rule isn't well-formed
          [nil, false]
        end
      end

      # Returns a context's bucket value as a floating-point value in `[0, 1)`.
      #
      # @param context [LDContext] the context properties
      # @param context_kind [String, nil] the context kind to match against
      # @param key [String] the feature flag key (or segment key, if this is for a segment rule)
      # @param bucket_by [String|Symbol] the name of the context attribute to be used for bucketing
      # @param salt [String] the feature flag's or segment's salt value
      # @return [Float, nil] the bucket value, from 0 inclusive to 1 exclusive
      # @raise [InvalidReferenceException] Raised if the clause.attribute is an invalid reference
      def self.bucket_context(context, context_kind, key, bucket_by, salt, seed)
        matched_context = context.individual_context(context_kind || LaunchDarkly::LDContext::KIND_DEFAULT)
        return nil if matched_context.nil?

        reference = (context_kind.nil? || context_kind.empty?) ? Reference.create_literal(bucket_by) : Reference.create(bucket_by)
        raise InvalidReferenceException.new(reference.error) unless reference.error.nil?

        context_value = matched_context.get_value_for_reference(reference)
        return 0.0 if context_value.nil?

        id_hash = bucketable_string_value(context_value)
        return 0.0 if id_hash.nil?

        if seed
          hash_key = "%d.%s" % [seed, id_hash]
        else
          hash_key = "%s.%s.%s" % [key, salt, id_hash]
        end

        hash_val = Digest::SHA1.hexdigest(hash_key)[0..14]
        hash_val.to_i(16) / Float(0xFFFFFFFFFFFFFFF)
      end

      private

      def self.bucketable_string_value(value)
        return value if value.is_a? String
        return value.to_s if value.is_a? Integer
        nil
      end
    end
  end
end
