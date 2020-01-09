
module LaunchDarkly
  module Impl
    # Encapsulates the logic for percentage rollouts.
    module EvaluatorBucketing
      # Applies either a fixed variation or a rollout for a rule (or the fallthrough rule).
      #
      # @param flag [Object] the feature flag
      # @param rule [Object] the rule
      # @param user [Object] the user properties
      # @return [Number] the variation index, or nil if there is an error
      def self.variation_index_for_user(flag, rule, user)
        variation = rule[:variation]
        return variation if !variation.nil? # fixed variation
        rollout = rule[:rollout]
        return nil if rollout.nil?
        variations = rollout[:variations]
        if !variations.nil? && variations.length > 0 # percentage rollout
          rollout = rule[:rollout]
          bucket_by = rollout[:bucketBy].nil? ? "key" : rollout[:bucketBy]
          bucket = bucket_user(user, flag[:key], bucket_by, flag[:salt])
          sum = 0;
          variations.each do |variate|
            sum += variate[:weight].to_f / 100000.0
            if bucket < sum
              return variate[:variation]
            end
          end
          # The user's bucket value was greater than or equal to the end of the last bucket. This could happen due
          # to a rounding error, or due to the fact that we are scaling to 100000 rather than 99999, or the flag
          # data could contain buckets that don't actually add up to 100000. Rather than returning an error in
          # this case (or changing the scaling, which would potentially change the results for *all* users), we
          # will simply put the user in the last bucket.
          variations[-1][:variation]
        else # the rule isn't well-formed
          nil
        end
      end

      # Returns a user's bucket value as a floating-point value in `[0, 1)`.
      #
      # @param user [Object] the user properties
      # @param key [String] the feature flag key (or segment key, if this is for a segment rule)
      # @param bucket_by [String|Symbol] the name of the user attribute to be used for bucketing
      # @param salt [String] the feature flag's or segment's salt value
      # @return [Number] the bucket value, from 0 inclusive to 1 exclusive
      def self.bucket_user(user, key, bucket_by, salt)
        return nil unless user[:key]

        id_hash = bucketable_string_value(EvaluatorOperators.user_value(user, bucket_by))
        if id_hash.nil?
          return 0.0
        end

        if user[:secondary]
          id_hash += "." + user[:secondary].to_s
        end

        hash_key = "%s.%s.%s" % [key, salt, id_hash]

        hash_val = (Digest::SHA1.hexdigest(hash_key))[0..14]
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
