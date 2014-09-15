require 'faraday/http_cache'
require 'json'
require 'digest/sha1'

module Launchdarkly
  class LdClient

    LONG_SCALE = Float(0xFFFFFFFFFFFFFFF) 
    
    def initialize(api_key, config = Config.default)
      store = ThreadSafeMemoryStore.new
      @api_key = api_key
      @config = config
      @client = Faraday.new do |builder|
        builder.use :http_cache, store: store

        builder.adapter Faraday.default_adapter
      end
    end

    def get_flag?(key, user, default=false)

      unless user
        return default
      end

      res = 
      @client.get (@config.base_uri + '/api/eval/features/' + key) do |req|
        req.headers['Authorization'] = 'api_key ' + @api_key
        req.headers['User-Agent'] = 'RubyClient/' + Launchdarkly::VERSION
      end

      feature = JSON.parse(res.body)

      val = evaluate(feature, user)

      val == nil ? default : val
    end

    def param_for_user(feature, user)
      if user.has_key? 'key' 
        id_hash = user['key']
      else
        return nil
      end

      if user.has_key? 'secondary'
        id_hash += '.' + user['secondary']
      end

      hash_key = "%s.%s.%s" % [feature['key'], feature['salt'], id_hash]
      hash_val = (Digest::SHA1.hexdigest(hash_key))[0..14]
      return hash_val.to_i(16) / LONG_SCALE
    end

    def match_target?(target, user)
      attrib = target['attribute']

      if attrib == 'key' or attrib == 'ip' or attrib == 'country'
        if user[attrib]
          u_value = user[attrib]
          return target['values'].include? u_value
        else
          return false
        end
      else # custom attribute
        unless user.has_key? 'custom'
          return false
        end
        unless user['custom'].include? attrib
          return false
        end
        u_value = user['custom'][attrib]
        if u_value.is_a? String or u_value.is_a? Numeric
          return target['values'].include? u_value
        elsif u_value.is_a? Array
          return ! ((target['values'] & u_value).empty?)
        end

        return false     
      end 

    end

    def match_variation?(variation, user)
      variation['targets'].each do |target|
        if match_target?(target, user)
          return true
        end
      end
      return false
    end

    def evaluate(feature, user)
      unless feature['on']
        return nil
      end

      param = param_for_user(feature, user)

      if param == nil
        return nil
      end

      feature['variations'].each do |variation|
        if match_variation?(variation, user)
          return variation['value']
        end
      end

      total = 0.0
      feature['variations'].each do |variation|
        total += variation['weight'].to_f / 100.0

        if param < total
          return variation['value']
        end
      end

      return nil

    end

    private :param_for_user, :match_target?, :match_variation?, :evaluate


  end
end