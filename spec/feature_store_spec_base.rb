require "spec_helper"

# Reusable test logic for testing FeatureStore implementations.
#
# Usage:
#
# 1. For a persistent store (database integration)
# class MyStoreTester
#   def initialize(options)
#     @options = options  # the test logic will pass in options like prefix and expiration
#   end
#   def create_feature_store
#     MyFeatureStoreClass.new_feature_store(@options)
#   end
#   def clear_data
#     # clear any existing data from the database, taking @options[:prefix] into account if any
#   end
# end
#
# describe "my persistent feature store" do
#   include_examples "persistent_feature_store", MyStoreTester
# end
#
# 2. For a non-persistent store (the in-memory implementation)
# class MyStoreTester
#   def create_feature_store
#     MyFeatureStoreClass.new_feature_store(@options)
#   end
# end
#
# describe "my feature store" do
#   include_examples "any_feature_store", MyStoreTester.new
# end

# Rather than testing with feature flag or segment data, we'll use this fake data kind
# to make it clear that feature stores need to be able to handle arbitrary data.
$things_kind = { namespace: "things" }

$key1 = "$thing1"
$thing1 = {
  key: $key1,
  name: "Thing 1",
  version: 11,
  deleted: false,
}
$unused_key = "no"

shared_examples "any_feature_store" do |store_tester|
  let(:store_tester) { store_tester }

  def with_store()
    ensure_stop(store_tester.create_feature_store) do |store|
      yield store
    end
  end

  def with_inited_store(things)
    things_hash = {}
    things.each { |thing| things_hash[thing[:key].to_sym] = thing }

    with_store do |s|
      s.init({ $things_kind => things_hash })
      yield s
    end
  end

  def new_version_plus(f, deltaVersion, attrs = {})
    f.clone.merge({ version: f[:version] + deltaVersion }).merge(attrs)
  end

  it "is not initialized by default" do
    with_store do |store|
      expect(store.initialized?).to eq false
    end
  end

  it "is initialized after calling init" do
    with_inited_store([]) do |store|
      expect(store.initialized?).to eq true
    end
  end

  it "can get existing item with symbol key" do
    with_inited_store([ $thing1 ]) do |store|
      expect(store.get($things_kind, $key1.to_sym)).to eq $thing1
    end
  end

  it "can get existing item with string key" do
    with_inited_store([ $thing1 ]) do |store|
      expect(store.get($things_kind, $key1.to_s)).to eq $thing1
    end
  end

  it "gets nil for nonexisting item" do
    with_inited_store([ $thing1 ]) do |store|
      expect(store.get($things_kind, $unused_key)).to be_nil
    end
  end

  it "returns nil for deleted item" do
    deleted_thing = $thing1.clone.merge({ deleted: true })
    with_inited_store([ deleted_thing ]) do |store|
      expect(store.get($things_kind, $key1)).to be_nil
    end
  end

  it "can get all items" do
    key2 = "thing2"
    thing2 = {
      key: key2,
      name: "Thing 2",
      version: 22,
      deleted: false,
    }
    with_inited_store([ $thing1, thing2 ]) do |store|
      expect(store.all($things_kind)).to eq ({ $key1.to_sym => $thing1, key2.to_sym => thing2 })
    end
  end

  it "filters out deleted items when getting all" do
    key2 = "thing2"
    thing2 = {
      key: key2,
      name: "Thing 2",
      version: 22,
      deleted: true,
    }
    with_inited_store([ $thing1, thing2 ]) do |store|
      expect(store.all($things_kind)).to eq ({ $key1.to_sym => $thing1 })
    end
  end

  it "can add new item" do
    with_inited_store([]) do |store|
      store.upsert($things_kind, $thing1)
      expect(store.get($things_kind, $key1)).to eq $thing1
    end
  end

  it "can update item with newer version" do
    with_inited_store([ $thing1 ]) do |store|
      $thing1_mod = new_version_plus($thing1, 1, { name: $thing1[:name] + ' updated' })
      store.upsert($things_kind, $thing1_mod)
      expect(store.get($things_kind, $key1)).to eq $thing1_mod
    end
  end

  it "cannot update item with same version" do
    with_inited_store([ $thing1 ]) do |store|
      $thing1_mod = $thing1.clone.merge({ name: $thing1[:name] + ' updated' })
      store.upsert($things_kind, $thing1_mod)
      expect(store.get($things_kind, $key1)).to eq $thing1
    end
  end

  it "cannot update feature with older version" do
    with_inited_store([ $thing1 ]) do |store|
      $thing1_mod = new_version_plus($thing1, -1, { name: $thing1[:name] + ' updated' })
      store.upsert($things_kind, $thing1_mod)
      expect(store.get($things_kind, $key1)).to eq $thing1
    end
  end

  it "can delete item with newer version" do
    with_inited_store([ $thing1 ]) do |store|
      store.delete($things_kind, $key1, $thing1[:version] + 1)
      expect(store.get($things_kind, $key1)).to be_nil
    end
  end

  it "cannot delete item with same version" do
    with_inited_store([ $thing1 ]) do |store|
      store.delete($things_kind, $key1, $thing1[:version])
      expect(store.get($things_kind, $key1)).to eq $thing1
    end
  end

  it "cannot delete item with older version" do
    with_inited_store([ $thing1 ]) do |store|
      store.delete($things_kind, $key1, $thing1[:version] - 1)
      expect(store.get($things_kind, $key1)).to eq $thing1
    end
  end

  it "stores Unicode data correctly" do
    flag = {
      key: "my-fancy-flag",
      name: "Tęst Feåtūre Flæg😺",
      version: 1,
      deleted: false,
    }
    with_inited_store([]) do |store|
      store.upsert(LaunchDarkly::FEATURES, flag)
      expect(store.get(LaunchDarkly::FEATURES, flag[:key])).to eq flag
    end
  end
end

shared_examples "persistent_feature_store" do |store_tester_class|
  base_options = { logger: $null_logger }

  # We'll loop through permutations of the following parameters. Note: in the future, the caching logic will
  # be separated out and implemented at a higher level of the SDK, so we won't have to test it for individual
  # persistent store implementations. Currently caching *is* implemented in a shared class (CachingStoreWrapper),
  # but the individual store implementations are wrapping themselves in that class, so they can't be tested
  # separately from it.

  caching_test_groups = [
    ["with caching", { expiration: 60 }],
    ["without caching", { expiration: 0 }],
  ]
  prefix_test_groups = [
    ["with default prefix", {}],
    ["with specified prefix", { prefix: "testprefix" }],
  ]

  caching_test_groups.each do |test_group_description, caching_options|
    context(test_group_description) do

      prefix_test_groups.each do |subgroup_description, prefix_options|
        # The following tests are done for each permutation of (caching/no caching) and (default prefix/specified prefix)
        context(subgroup_description) do
          options = caching_options.merge(prefix_options).merge(base_options)

          store_tester = store_tester_class.new(base_options)

          before(:each) { store_tester.clear_data }

          include_examples "any_feature_store", store_tester

          it "can detect if another instance has initialized the store" do
            ensure_stop(store_tester.create_feature_store) do |store1|
              store1.init({})
              ensure_stop(store_tester.create_feature_store) do |store2|
                expect(store2.initialized?).to eq true
              end
            end
          end

          it "can read data written by another instance" do
            ensure_stop(store_tester.create_feature_store) do |store1|
              store1.init({ $things_kind => { $key1.to_sym => $thing1 } })
              ensure_stop(store_tester.create_feature_store) do |store2|
                expect(store2.get($things_kind, $key1)).to eq $thing1
              end
            end
          end
        end
      end

      # The following tests are done for each permutation of (caching/no caching)
      it "is independent from other stores with different prefixes" do
        factory_a = store_tester_class.new({ prefix: "a" }.merge(caching_options).merge(base_options))
        factory_b = store_tester_class.new({ prefix: "b" }.merge(caching_options).merge(base_options))
        factory_a.clear_data
        factory_b.clear_data

        ensure_stop(factory_a.create_feature_store) do |store_a|
          store_a.init({ $things_kind => { $key1.to_sym => $thing1 } })
          ensure_stop(factory_b.create_feature_store) do |store_b1|
            store_b1.init({ $things_kind => {} })
          end
          ensure_stop(factory_b.create_feature_store) do |store_b2|  # this ensures we're not just reading cached data
            expect(store_b2.get($things_kind, $key1)).to be_nil
            expect(store_a.get($things_kind, $key1)).to eq $thing1
          end
        end
      end
    end
  end
end
