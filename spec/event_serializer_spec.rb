require "spec_helper"

describe LaunchDarkly::EventSerializer do
  subject { LaunchDarkly::EventSerializer }

  let(:base_config) { LaunchDarkly::Config.new }
  let(:config_with_all_attrs_private) { LaunchDarkly::Config.new({ all_attributes_private: true })}
  let(:config_with_some_attrs_private) { LaunchDarkly::Config.new({ private_attribute_names: ['firstName', 'bizzle'] })}

  # users to serialize

  let(:user) {
    { key: 'abc', firstName: 'Sue', custom: { bizzle: 'def', dizzle: 'ghi' }}
  }

  let(:user_specifying_own_private_attr) {
    u = user.clone
    u[:privateAttributeNames] = [ 'dizzle', 'unused' ]
    u
  }

  # expected results from serializing user

  let(:user_with_all_attrs_hidden) {
    { key: 'abc', custom: { }, privateAttrs: [ 'bizzle', 'dizzle', 'firstName' ]}
  }

  let(:user_with_some_attrs_hidden) {
    { key: 'abc', custom: { dizzle: 'ghi' }, privateAttrs: [ 'bizzle', 'firstName' ]}
  }

  let(:user_with_own_specified_attr_hidden) {
    { key: 'abc', firstName: 'Sue', custom: { bizzle: 'def' }, privateAttrs: [ 'dizzle' ]}
  }


  def make_event(user)
    {
      creationDate: 1000000,
      key: 'xyz',
      kind: 'thing',
      user: user
    }
  end

  def parse_results(js)
    JSON.parse(js, symbolize_names: true)
  end

  describe "serialize_events" do
    it "includes all user attributes by default" do
      es = LaunchDarkly::EventSerializer.new(base_config)
      event = make_event(user)
      j = es.serialize_events([event])
      expect(parse_results(j)).to eq [event]
    end

    it "hides all except key if all_attributes_private is true" do
      es = LaunchDarkly::EventSerializer.new(config_with_all_attrs_private)
      event = make_event(user)
      j = es.serialize_events([event])
      expect(parse_results(j)).to eq [make_event(user_with_all_attrs_hidden)]
    end

    it "hides some attributes if private_attribute_names is set" do
      es = LaunchDarkly::EventSerializer.new(config_with_some_attrs_private)
      event = make_event(user)
      j = es.serialize_events([event])
      expect(parse_results(j)).to eq [make_event(user_with_some_attrs_hidden)]
    end

    it "hides attributes specified in per-user privateAttrs" do
      es = LaunchDarkly::EventSerializer.new(base_config)
      event = make_event(user_specifying_own_private_attr)
      j = es.serialize_events([event])
      expect(parse_results(j)).to eq [make_event(user_with_own_specified_attr_hidden)]
    end

    it "looks at both per-user privateAttrs and global config" do
      es = LaunchDarkly::EventSerializer.new(config_with_some_attrs_private)
      event = make_event(user_specifying_own_private_attr)
      j = es.serialize_events([event])
      expect(parse_results(j)).to eq [make_event(user_with_all_attrs_hidden)]
    end
  end
end
