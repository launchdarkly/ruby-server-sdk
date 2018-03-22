require "spec_helper"

describe LaunchDarkly::UserFilter do
  subject { LaunchDarkly::UserFilter }

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

  let(:user_with_unknown_top_level_attrs) {
    { key: 'abc', firstName: 'Sue', species: 'human', hatSize: 6, custom: { bizzle: 'def', dizzle: 'ghi' }}
  }

  let(:anon_user) {
    { key: 'abc', anonymous: 'true', custom: { bizzle: 'def', dizzle: 'ghi' }}
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

  let(:anon_user_with_all_attrs_hidden) {
    { key: 'abc', anonymous: 'true', custom: { }, privateAttrs: [ 'bizzle', 'dizzle' ]}
  }

  describe "serialize_events" do
    it "includes all user attributes by default" do
      uf = LaunchDarkly::UserFilter.new(base_config)
      result = uf.transform_user_props(user)
      expect(result).to eq user
    end

    it "hides all except key if all_attributes_private is true" do
      uf = LaunchDarkly::UserFilter.new(config_with_all_attrs_private)
      result = uf.transform_user_props(user)
      expect(result).to eq user_with_all_attrs_hidden
    end

    it "hides some attributes if private_attribute_names is set" do
      uf = LaunchDarkly::UserFilter.new(config_with_some_attrs_private)
      result = uf.transform_user_props(user)
      expect(result).to eq user_with_some_attrs_hidden
    end

    it "hides attributes specified in per-user privateAttrs" do
      uf = LaunchDarkly::UserFilter.new(base_config)
      result = uf.transform_user_props(user_specifying_own_private_attr)
      expect(result).to eq user_with_own_specified_attr_hidden
    end

    it "looks at both per-user privateAttrs and global config" do
      uf = LaunchDarkly::UserFilter.new(config_with_some_attrs_private)
      result = uf.transform_user_props(user_specifying_own_private_attr)
      expect(result).to eq user_with_all_attrs_hidden
    end

    it "strips out any unknown top-level attributes" do
      uf = LaunchDarkly::UserFilter.new(base_config)
      result = uf.transform_user_props(user_with_unknown_top_level_attrs)
      expect(result).to eq user
    end

    it "leaves the anonymous attribute as is" do
      uf = LaunchDarkly::UserFilter.new(config_with_all_attrs_private)
      result = uf.transform_user_props(anon_user)
      expect(result).to eq anon_user_with_all_attrs_hidden
    end
  end
end
