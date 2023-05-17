require "spec_helper"

RSpec.shared_examples "segment_store" do |create_store_method|

  let(:segment0) {
    {
      key: "test-segment",
      version: 11,
      salt: "718ea30a918a4eba8734b57ab1a93227",
      rules: [],
    }
  }
  let(:key0) { segment0[:key].to_sym }

  let!(:store) do
    s = create_store_method.call()
    s.init({ key0 => segment0 })
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
    expect(store.get(key0)).to eq segment0
  end

  it "can get existing feature with string key" do
    expect(store.get(key0.to_s)).to eq segment0
  end

  it "gets nil for nonexisting feature" do
    expect(store.get('nope')).to be_nil
  end

  it "can get all features" do
    feature1 = segment0.clone
    feature1[:key] = "test-feature-flag1"
    feature1[:version] = 5
    feature1[:on] = false
    store.upsert(:"test-feature-flag1", feature1)
    expect(store.all).to eq ({ key0 => segment0, :"test-feature-flag1" => feature1 })
  end

  it "can add new feature" do
    feature1 = segment0.clone
    feature1[:key] = "test-feature-flag1"
    feature1[:version] = 5
    feature1[:on] = false
    store.upsert(:"test-feature-flag1", feature1)
    expect(store.get(:"test-feature-flag1")).to eq feature1
  end

  it "can update feature with newer version" do
    f1 = new_version_plus(segment0, 1, { on: !segment0[:on] })
    store.upsert(key0, f1)
    expect(store.get(key0)).to eq f1
  end

  it "cannot update feature with same version" do
    f1 = new_version_plus(segment0, 0, { on: !segment0[:on] })
    store.upsert(key0, f1)
    expect(store.get(key0)).to eq segment0
  end

  it "cannot update feature with older version" do
    f1 = new_version_plus(segment0, -1, { on: !segment0[:on] })
    store.upsert(key0, f1)
    expect(store.get(key0)).to eq segment0
  end

  it "can delete feature with newer version" do
    store.delete(key0, segment0[:version] + 1)
    expect(store.get(key0)).to be_nil
  end

  it "cannot delete feature with same version" do
    store.delete(key0, segment0[:version])
    expect(store.get(key0)).to eq segment0
  end

  it "cannot delete feature with older version" do
    store.delete(key0, segment0[:version] - 1)
    expect(store.get(key0)).to eq segment0
  end
end
