require "json"
require "set"

module LaunchDarkly
  class UserFilter
    def initialize(config)
      @all_attributes_private = config.all_attributes_private
      @private_attribute_names = Set.new(config.private_attribute_names.map(&:to_sym))
    end

    def transform_user_props(user_props)
      return nil if user_props.nil?
      
      user_private_attrs = Set.new((user_props[:privateAttributeNames] || []).map(&:to_sym))

      filtered_user_props, removed = filter_values(user_props, user_private_attrs, ALLOWED_TOP_LEVEL_KEYS, IGNORED_TOP_LEVEL_KEYS)
      if user_props.has_key?(:custom)
        filtered_user_props[:custom], removed_custom = filter_values(user_props[:custom], user_private_attrs)
        removed.merge(removed_custom)
      end

      unless removed.empty?
        # note, :privateAttributeNames is what the developer sets; :privateAttrs is what we send to the server
        filtered_user_props[:privateAttrs] = removed.to_a.sort.map { |s| s.to_s }
      end
      return filtered_user_props
    end

    private

    ALLOWED_TOP_LEVEL_KEYS = Set.new([:key, :secondary, :ip, :country, :email,
                :firstName, :lastName, :avatar, :name, :anonymous, :custom])
    IGNORED_TOP_LEVEL_KEYS = Set.new([:custom, :key, :anonymous])

    def filter_values(props, user_private_attrs, allowed_keys = [], keys_to_leave_as_is = [])
      is_valid_key = lambda { |key| allowed_keys.empty? || allowed_keys.include?(key) }
      removed_keys = Set.new(props.keys.select { |key|
        # Note that if is_valid_key returns false, we don't explicitly *remove* the key (which would place
        # it in the privateAttrs list) - we just silently drop it when we calculate filtered_hash.
        is_valid_key.call(key) && !keys_to_leave_as_is.include?(key) && private_attr?(key, user_private_attrs)
      })
      filtered_hash = props.select { |key, value| !removed_keys.include?(key) && is_valid_key.call(key) }
      [filtered_hash, removed_keys]
    end

    def private_attr?(name, user_private_attrs)
      @all_attributes_private || @private_attribute_names.include?(name) || user_private_attrs.include?(name)
    end
  end
end
