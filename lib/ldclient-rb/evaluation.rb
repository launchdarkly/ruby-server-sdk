module LaunchDarkly

  module Evaluation
    BUILTINS = [:key, :ip, :country, :email, :firstName, :lastName, :avatar, :name, :anonymous]

    def param_for_user(feature, user)
      return nil unless user[:key]

      id_hash = user[:key]
      if user[:secondary]
        id_hash += "." + user[:secondary]
      end

      hash_key = "%s.%s.%s" % [feature[:key], feature[:salt], id_hash]

      hash_val = (Digest::SHA1.hexdigest(hash_key))[0..14]
      hash_val.to_i(16) / Float(0xFFFFFFFFFFFFFFF)
    end

    def match_target?(target, user)
      attrib = target[:attribute].to_sym

      if BUILTINS.include?(attrib)
        return false unless user[attrib]

        u_value = user[attrib]
        return target[:values].include? u_value
      else # custom attribute
        return false unless user[:custom]
        return false unless user[:custom].include? attrib

        u_value = user[:custom][attrib]
        if u_value.is_a? Array
          return ! ((target[:values] & u_value).empty?)
        else
          return target[:values].include? u_value
        end

        return false
      end
    end

    def match_user?(variation, user)
      if variation[:userTarget]
        return match_target?(variation[:userTarget], user)
      end
      false
    end

    def find_user_match(feature, user)
      feature[:variations].each do |variation|
        return variation[:value] if match_user?(variation, user)
      end
      nil
    end

    def match_variation?(variation, user)
      variation[:targets].each do |target|
        if !!variation[:userTarget] && target[:attribute].to_sym == :key
          next
        end

        if match_target?(target, user)
          return true
        end
      end
      false
    end

    def find_target_match(feature, user)
      feature[:variations].each do |variation|
        return variation[:value] if match_variation?(variation, user)
      end
      nil
    end

    def find_weight_match(feature, param)
      total = 0.0
      feature[:variations].each do |variation|
        total += variation[:weight].to_f / 100.0

        return variation[:value] if param < total
      end

      nil
    end

    def evaluate(feature, user)
      if feature.nil?
        @config.logger.debug("[LDClient] Nil feature in evaluate")
        return nil
      end

      @config.logger.debug("[LDClient] Evaluating feature: #{feature.to_json}")

      if !feature[:on]
        @config.logger.debug("[LDClient] Feature #{feature[:key]} is off")
        return nil
      end

      param = param_for_user(feature, user)
      return nil if param.nil?

      value = find_user_match(feature, user)
      if !value.nil?
        @config.logger.debug("[LDClient] Evaluated feature #{feature[:key]} to #{value} from user targeting match")
        return value
      end

      value = find_target_match(feature, user)
      if !value.nil?
        @config.logger.debug("[LDClient] Evaluated feature #{feature[:key]} to #{value} from rule match")
        return value
      end

      value = find_weight_match(feature, param)
      @config.logger.debug("[LDClient] Evaluated feature #{feature[:key]} to #{value} from percentage rollout")
      value
    end
  end

end