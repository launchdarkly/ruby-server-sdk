require "spec_helper"

shared_examples "feature_store" do |create_store_method, clear_data_method|

  # Rather than testing with feature flag or segment data, we'll use this fake data kind
  # to make it clear that feature stores need to be able to handle arbitrary data.
  let(:things_kind) { { namespace: "things" } }

  let(:key1) { "thing1" }
  let(:thing1) {
    {
      key: key1,
      name: "Thing 1",
      version: 11,
      deleted: false
    }
  }
  let(:unused_key) { "no" }

  let(:create_store) { create_store_method } # just to avoid a scope issue
  let(:clear_data) { clear_data_method }

  def with_store(opts = {})
    s = create_store.call(opts)
    begin
      yield s
    ensure
      s.stop
    end
  end

  def with_inited_store(things)
    things_hash = {}
    things.each { |thing| things_hash[thing[:key].to_sym] = thing }

    with_store do |s|
      s.init({ things_kind => things_hash })
      yield s
    end
  end

  def new_version_plus(f, deltaVersion, attrs = {})
    f.clone.merge({ version: f[:version] + deltaVersion }).merge(attrs)
  end

  before(:each) do
    clear_data.call if !clear_data.nil?
  end

  # This block of tests is only run if the clear_data method is defined, meaning that this is a persistent store
  # that operates on a database that can be shared with other store instances (as opposed to the in-memory store,
  # which has its own private storage).
  if !clear_data_method.nil?
    it "is not initialized by default" do
      with_store do |store|
        expect(store.initialized?).to eq false
      end
    end

    it "can detect if another instance has initialized the store" do
      with_store do |store1|
        store1.init({})
        with_store do |store2|
          expect(store2.initialized?).to eq true
        end
      end
    end

    it "can read data written by another instance" do
      with_store do |store1|
        store1.init({ things_kind => { key1.to_sym => thing1 } })
        with_store do |store2|
          expect(store2.get(things_kind, key1)).to eq thing1
        end
      end
    end

    it "is independent from other stores with different prefixes" do
      with_store({ prefix: "a" }) do |store_a|
        store_a.init({ things_kind => { key1.to_sym => thing1 } })
        with_store({ prefix: "b" }) do |store_b|
          store_b.init({ things_kind => {} })
        end
        with_store({ prefix: "b" }) do |store_b1|  # this ensures we're not just reading cached data
          expect(store_b1.get(things_kind, key1)).to be_nil
          expect(store_a.get(things_kind, key1)).to eq thing1
        end
      end
    end
  end

  it "is initialized after calling init" do
    with_inited_store([]) do |store|
      expect(store.initialized?).to eq true
    end
  end

  it "can get existing item with symbol key" do
    with_inited_store([ thing1 ]) do |store|
      expect(store.get(things_kind, key1.to_sym)).to eq thing1
    end
  end

  it "can get existing item with string key" do
    with_inited_store([ thing1 ]) do |store|
      expect(store.get(things_kind, key1.to_s)).to eq thing1
    end
  end

  it "gets nil for nonexisting item" do
    with_inited_store([ thing1 ]) do |store|
      expect(store.get(things_kind, unused_key)).to be_nil
    end
  end

  it "returns nil for deleted item" do
    deleted_thing = thing1.clone.merge({ deleted: true })
    with_inited_store([ deleted_thing ]) do |store|
      expect(store.get(things_kind, key1)).to be_nil
    end
  end

  it "can get all items" do
    key2 = "thing2"
    thing2 = {
      key: key2,
      name: "Thing 2",
      version: 22,
      deleted: false
    }
    with_inited_store([ thing1, thing2 ]) do |store|
      expect(store.all(things_kind)).to eq ({ key1.to_sym => thing1, key2.to_sym => thing2 })
    end
  end

  it "filters out deleted items when getting all" do
    key2 = "thing2"
    thing2 = {
      key: key2,
      name: "Thing 2",
      version: 22,
      deleted: true
    }
    with_inited_store([ thing1, thing2 ]) do |store|
      expect(store.all(things_kind)).to eq ({ key1.to_sym => thing1 })
    end
  end

  it "can add new item" do
    with_inited_store([]) do |store|
      store.upsert(things_kind, thing1)
      expect(store.get(things_kind, key1)).to eq thing1
    end
  end

  it "can update item with newer version" do
    with_inited_store([ thing1 ]) do |store|
      thing1_mod = new_version_plus(thing1, 1, { name: thing1[:name] + ' updated' })
      store.upsert(things_kind, thing1_mod)
      expect(store.get(things_kind, key1)).to eq thing1_mod
    end
  end

  it "cannot update item with same version" do
    with_inited_store([ thing1 ]) do |store|
      thing1_mod = thing1.clone.merge({ name: thing1[:name] + ' updated' })
      store.upsert(things_kind, thing1_mod)
      expect(store.get(things_kind, key1)).to eq thing1
    end
  end

  it "cannot update feature with older version" do
    with_inited_store([ thing1 ]) do |store|
      thing1_mod = new_version_plus(thing1, -1, { name: thing1[:name] + ' updated' })
      store.upsert(things_kind, thing1_mod)
      expect(store.get(things_kind, key1)).to eq thing1
    end
  end

  it "can delete item with newer version" do
    with_inited_store([ thing1 ]) do |store|
      store.delete(things_kind, key1, thing1[:version] + 1)
      expect(store.get(things_kind, key1)).to be_nil
    end
  end

  it "cannot delete item with same version" do
    with_inited_store([ thing1 ]) do |store|
      store.delete(things_kind, key1, thing1[:version])
      expect(store.get(things_kind, key1)).to eq thing1
    end
  end

  it "cannot delete item with older version" do
    with_inited_store([ thing1 ]) do |store|
      store.delete(things_kind, key1, thing1[:version] - 1)
      expect(store.get(things_kind, key1)).to eq thing1
    end
  end

  it "stores Unicode data correctly" do
    flag = {
      key: "my-fancy-flag",
      name: "Tęst Feåtūre Flæg😺",
      version: 1,
      deleted: false
    }
    store.upsert(LaunchDarkly::FEATURES, flag)
    expect(store.get(LaunchDarkly::FEATURES, flag[:key])).to eq flag
  end
end
