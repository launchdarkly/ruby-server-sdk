require "json"

module LaunchDarkly
  class EventSerializer
    def initialize(config)
      @all_attributes_private = config.all_attributes_private
      @private_attribute_names = Set.new(config.private_attribute_names.map(&:to_sym))
    end

    def serialize_events(events)
      events.map { |event|
        Hash[event.map { |key, value|
          [key, (key.to_sym == :user) ? transform_user_props(value) : value]
        }]
      }.to_json
    end

    private

    IGNORED_TOP_LEVEL_KEYS = Set.new([:custom, :key, :privateAttributeNames])
    STRIPPED_TOP_LEVEL_KEYS = Set.new([:privateAttributeNames])

    def filter_values(props, user_private_attrs, ignore=[])
      removed_keys = Set.new(props.keys.select { |key|
        !ignore.include?(key) && private_attr?(key, user_private_attrs)
      })
      filtered_hash = props.select { |key, value| !removed_keys.include?(key) && !STRIPPED_TOP_LEVEL_KEYS.include?(key) }
      [filtered_hash, removed_keys]
    end

    def private_attr?(name, user_private_attrs)
      @all_attributes_private || @private_attribute_names.include?(name) || user_private_attrs.include?(name)
    end

    def transform_user_props(user_props)
      user_private_attrs = Set.new((user_props[:privateAttributeNames] || []).map(&:to_sym))

      filtered_user_props, removed = filter_values(user_props, user_private_attrs, IGNORED_TOP_LEVEL_KEYS)
      if user_props.has_key?(:custom)
        filtered_user_props[:custom], removed_custom = filter_values(user_props[:custom], user_private_attrs)
        removed.merge(removed_custom)
      end

      unless removed.empty?
        # note, :privateAttributeNames is what the developer sets; :privateAttrs is what we send to the server
        filtered_user_props[:privateAttrs] = removed.to_a.sort
      end
      return filtered_user_props
    end
  end
end
