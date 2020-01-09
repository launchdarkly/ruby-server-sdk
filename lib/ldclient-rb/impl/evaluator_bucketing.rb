
module LaunchDarkly
  module Impl
    # Encapsulates the logic for percentage rollouts.
    module EvaluatorBucketing
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
