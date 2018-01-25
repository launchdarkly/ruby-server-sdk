require "spec_helper"

RSpec.shared_examples "feature_store" do |create_store_method|

  let(:feature0) {
    {
      key: "test-feature-flag",
      version: 11,
      on: true,
      prerequisites: [],
      salt: "718ea30a918a4eba8734b57ab1a93227",
      sel: "fe1244e5378c4f99976c9634e33667c6",
      targets: [
        {
           values: [ "alice" ],
           variation: 0
        },
        {
           values: [ "bob" ],
           variation: 1
        }
      ],
      rules: [],
      fallthrough: { variation: 0 },
      offVariation: 1,
      variations: [ true, false ],
      deleted: false
    }
  }
  let(:key0) { feature0[:key].to_sym }

  let!(:store) do
    s = create_store_method.call()
    s.init(LaunchDarkly::FEATURES => { key0 => feature0 })
    s
  end

  def new_version_plus(f, deltaVersion, attrs = {})
    f1 = f.clone
    f1[:version] = f[:version] + deltaVersion
    f1.update(attrs)
    f1
  end


  it "is initialized" do
    expect(store.initialized?).to eq true
  end

  it "can get existing feature with symbol key" do
    expect(store.get(LaunchDarkly::FEATURES, key0)).to eq feature0
  end

  it "can get existing feature with string key" do
    expect(store.get(LaunchDarkly::FEATURES, key0.to_s)).to eq feature0
  end

  it "gets nil for nonexisting feature" do
    expect(store.get(LaunchDarkly::FEATURES, 'nope')).to be_nil
  end

  it "can get all features" do
    feature1 = feature0.clone
    feature1[:key] = "test-feature-flag1"
    feature1[:version] = 5
    feature1[:on] = false
    store.upsert(LaunchDarkly::FEATURES, feature1)
    expect(store.all(LaunchDarkly::FEATURES)).to eq ({ key0 => feature0, :"test-feature-flag1" => feature1 })
  end

  it "can add new feature" do
    feature1 = feature0.clone
    feature1[:key] = "test-feature-flag1"
    feature1[:version] = 5
    feature1[:on] = false
    store.upsert(LaunchDarkly::FEATURES, feature1)
    expect(store.get(LaunchDarkly::FEATURES, :"test-feature-flag1")).to eq feature1
  end

  it "can update feature with newer version" do
    f1 = new_version_plus(feature0, 1, { on: !feature0[:on] })
    store.upsert(LaunchDarkly::FEATURES, f1)
    expect(store.get(LaunchDarkly::FEATURES, key0)).to eq f1
  end

  it "cannot update feature with same version" do
    f1 = new_version_plus(feature0, 0, { on: !feature0[:on] })
    store.upsert(LaunchDarkly::FEATURES, f1)
    expect(store.get(LaunchDarkly::FEATURES, key0)).to eq feature0
  end

  it "cannot update feature with older version" do
    f1 = new_version_plus(feature0, -1, { on: !feature0[:on] })
    store.upsert(LaunchDarkly::FEATURES, f1)
    expect(store.get(LaunchDarkly::FEATURES, key0)).to eq feature0
  end

  it "can delete feature with newer version" do
    store.delete(LaunchDarkly::FEATURES, key0, feature0[:version] + 1)
    expect(store.get(LaunchDarkly::FEATURES, key0)).to be_nil
  end

  it "cannot delete feature with same version" do
    store.delete(LaunchDarkly::FEATURES, key0, feature0[:version])
    expect(store.get(LaunchDarkly::FEATURES, key0)).to eq feature0
  end

  it "cannot delete feature with older version" do
    store.delete(LaunchDarkly::FEATURES, key0, feature0[:version] - 1)
    expect(store.get(LaunchDarkly::FEATURES, key0)).to eq feature0
  end
end
