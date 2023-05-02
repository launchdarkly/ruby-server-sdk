require "spec_helper"

describe LaunchDarkly::Integrations::Util::CachingStoreWrapper do
  subject { LaunchDarkly::Integrations::Util::CachingStoreWrapper }

  THINGS = { namespace: "things" }

  it "monitoring enabled if available is defined" do
    [true, false].each do |expected|
      core = double
      allow(core).to receive(:available?).and_return(expected)
      wrapper = subject.new(core, {})

      expect(wrapper.monitoring_enabled?).to be true
      expect(wrapper.available?).to be expected
    end
  end

  it "available is false if core doesn't support monitoring" do
    core = double
    wrapper = subject.new(core, {})

    expect(wrapper.monitoring_enabled?).to be false
    expect(wrapper.available?).to be false
  end

  shared_examples "tests" do |cached|
    opts = cached ? { expiration: 30 } : { expiration: 0 }

    it "gets item" do
      core = MockCore.new
      wrapper = subject.new(core, opts)
      key = "flag"
      itemv1 = { key: key, version: 1 }
      itemv2 = { key: key, version: 2 }

      core.force_set(THINGS, itemv1)
      expect(wrapper.get(THINGS, key)).to eq itemv1

      core.force_set(THINGS, itemv2)
      expect(wrapper.get(THINGS, key)).to eq (cached ? itemv1 : itemv2)  # if cached, we will not see the new underlying value yet
    end

    it "gets deleted item" do
      core = MockCore.new
      wrapper = subject.new(core, opts)
      key = "flag"
      itemv1 = { key: key, version: 1, deleted: true }
      itemv2 = { key: key, version: 2, deleted: false }

      core.force_set(THINGS, itemv1)
      expect(wrapper.get(THINGS, key)).to eq nil  # item is filtered out because deleted is true

      core.force_set(THINGS, itemv2)
      expect(wrapper.get(THINGS, key)).to eq (cached ? nil : itemv2)  # if cached, we will not see the new underlying value yet
    end

    it "gets missing item" do
      core = MockCore.new
      wrapper = subject.new(core, opts)
      key = "flag"
      item = { key: key, version: 1 }

      expect(wrapper.get(THINGS, key)).to eq nil

      core.force_set(THINGS, item)
      expect(wrapper.get(THINGS, key)).to eq (cached ? nil : item)  # the cache can retain a nil result
    end

    it "gets all items" do
      core = MockCore.new
      wrapper = subject.new(core, opts)
      item1 = { key: "flag1", version: 1 }
      item2 = { key: "flag2", version: 1 }

      core.force_set(THINGS, item1)
      core.force_set(THINGS, item2)
      expect(wrapper.all(THINGS)).to eq({ item1[:key] => item1, item2[:key] => item2 })

      core.force_remove(THINGS, item2[:key])
      expect(wrapper.all(THINGS)).to eq (cached ?
        { item1[:key] => item1, item2[:key] => item2 } :
        { item1[:key] => item1 })
    end

    it "gets all items filtering out deleted items" do
      core = MockCore.new
      wrapper = subject.new(core, opts)
      item1 = { key: "flag1", version: 1 }
      item2 = { key: "flag2", version: 1, deleted: true }

      core.force_set(THINGS, item1)
      core.force_set(THINGS, item2)
      expect(wrapper.all(THINGS)).to eq({ item1[:key] => item1 })
    end

    it "upserts item successfully" do
      core = MockCore.new
      wrapper = subject.new(core, opts)
      key = "flag"
      itemv1 = { key: key, version: 1 }
      itemv2 = { key: key, version: 2 }

      wrapper.upsert(THINGS, itemv1)
      expect(core.data[THINGS][key]).to eq itemv1

      wrapper.upsert(THINGS, itemv2)
      expect(core.data[THINGS][key]).to eq itemv2

      # if we have a cache, verify that the new item is now cached by writing a different value
      # to the underlying data - Get should still return the cached item
      if cached
        itemv3 = { key: key, version: 3 }
        core.force_set(THINGS, itemv3)
      end

      expect(wrapper.get(THINGS, key)).to eq itemv2
    end

    it "deletes item" do
      core = MockCore.new
      wrapper = subject.new(core, opts)
      key = "flag"
      itemv1 = { key: key, version: 1 }
      itemv2 = { key: key, version: 2, deleted: true }
      itemv3 = { key: key, version: 3 }

      core.force_set(THINGS, itemv1)
      expect(wrapper.get(THINGS, key)).to eq itemv1

      wrapper.delete(THINGS, key, 2)
      expect(core.data[THINGS][key]).to eq itemv2

      core.force_set(THINGS, itemv3)  # make a change that bypasses the cache

      expect(wrapper.get(THINGS, key)).to eq (cached ? nil : itemv3)
    end
  end

  context "cached" do
    include_examples "tests", true

    cached_opts = { expiration: 30 }

    it "get uses values from init" do
      core = MockCore.new
      wrapper = subject.new(core, cached_opts)
      item1 = { key: "flag1", version: 1 }
      item2 = { key: "flag2", version: 1 }

      wrapper.init({ THINGS => { item1[:key] => item1, item2[:key] => item2 } })
      core.force_remove(THINGS, item1[:key])

      expect(wrapper.get(THINGS, item1[:key])).to eq item1
    end

    it "get all uses values from init" do
      core = MockCore.new
      wrapper = subject.new(core, cached_opts)
      item1 = { key: "flag1", version: 1 }
      item2 = { key: "flag2", version: 1 }

      wrapper.init({ THINGS => { item1[:key] => item1, item2[:key] => item2 } })
      core.force_remove(THINGS, item1[:key])

      expect(wrapper.all(THINGS)).to eq ({ item1[:key] => item1, item2[:key] => item2 })
    end

    it "upsert doesn't update cache if unsuccessful" do
      # This is for an upsert where the data in the store has a higher version. In an uncached
      # store, this is just a no-op as far as the wrapper is concerned so there's nothing to
      # test here. In a cached store, we need to verify that the cache has been refreshed
      # using the data that was found in the store.
      core = MockCore.new
      wrapper = subject.new(core, cached_opts)
      key = "flag"
      itemv1 = { key: key, version: 1 }
      itemv2 = { key: key, version: 2 }

      wrapper.upsert(THINGS, itemv2)
      expect(core.data[THINGS][key]).to eq itemv2

      wrapper.upsert(THINGS, itemv1)
      expect(core.data[THINGS][key]).to eq itemv2  # value in store remains the same

      itemv3 = { key: key, version: 3 }
      core.force_set(THINGS, itemv3)  # bypasses cache so we can verify that itemv2 is in the cache
      expect(wrapper.get(THINGS, key)).to eq itemv2
    end

    it "initialized? can cache false result" do
      core = MockCore.new
      wrapper = subject.new(core, { expiration: 0.2 })  # use a shorter cache TTL for this test

      expect(wrapper.initialized?).to eq false
      expect(core.inited_query_count).to eq 1

      core.inited = true
      expect(wrapper.initialized?).to eq false
      expect(core.inited_query_count).to eq 1

      sleep(0.5)

      expect(wrapper.initialized?).to eq true
      expect(core.inited_query_count).to eq 2

      # From this point on it should remain true and the method should not be called
      expect(wrapper.initialized?).to eq true
      expect(core.inited_query_count).to eq 2
    end
  end

  context "uncached" do
    include_examples "tests", false

    uncached_opts = { expiration: 0 }

    it "queries internal initialized state only if not already inited" do
      core = MockCore.new
      wrapper = subject.new(core, uncached_opts)

      expect(wrapper.initialized?).to eq false
      expect(core.inited_query_count).to eq 1

      core.inited = true
      expect(wrapper.initialized?).to eq true
      expect(core.inited_query_count).to eq 2

      core.inited = false
      expect(wrapper.initialized?).to eq true
      expect(core.inited_query_count).to eq 2
    end

    it "does not query internal initialized state if init has been called" do
      core = MockCore.new
      wrapper = subject.new(core, uncached_opts)

      expect(wrapper.initialized?).to eq false
      expect(core.inited_query_count).to eq 1

      wrapper.init({})

      expect(wrapper.initialized?).to eq true
      expect(core.inited_query_count).to eq 1
    end
  end

  class MockCore
    def initialize
      @data = {}
      @inited = false
      @inited_query_count = 0
    end

    attr_reader :data
    attr_reader :inited_query_count
    attr_accessor :inited

    def force_set(kind, item)
      @data[kind] = {} unless @data.has_key?(kind)
      @data[kind][item[:key]] = item
    end

    def force_remove(kind, key)
      @data[kind].delete(key) if @data.has_key?(kind)
    end

    def init_internal(all_data)
      @data = all_data
      @inited = true
    end

    def get_internal(kind, key)
      items = @data[kind]
      items.nil? ? nil : items[key]
    end

    def get_all_internal(kind)
      @data[kind]
    end

    def upsert_internal(kind, item)
      @data[kind] = {} unless @data.has_key?(kind)
      old_item = @data[kind][item[:key]]
      return old_item if !old_item.nil? && old_item[:version] >= item[:version]
      @data[kind][item[:key]] = item
      item
    end

    def initialized_internal?
      @inited_query_count = @inited_query_count + 1
      @inited
    end
  end
end
