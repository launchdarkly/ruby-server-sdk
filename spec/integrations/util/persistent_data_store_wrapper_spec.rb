require "spec_helper"

module LaunchDarkly
  module Integrations
    describe Util::PersistentDataStoreWrapper do
      subject { Util::PersistentDataStoreWrapper }

      THINGS = Interfaces::DataStore::DataKind.new(namespace: "things", priority: 0)

      it "reports monitoring enabled and gets availability from the core" do
        [true, false].each do |expected|
          core = double
          allow(core).to receive(:available?).and_return(expected)
          wrapper = subject.new(core, {})

          expect(wrapper.monitoring_enabled?).to be true
          expect(wrapper.available?).to be expected
        end
      end

      it "stops the core" do
        core = double
        expect(core).to receive(:stop).once
        subject.new(core, {}).stop
      end

      shared_examples "tests" do |cached|
        opts = cached ? { expiration: 30 } : { expiration: 0 }

        it "gives the core serialized items" do
          core = MockCore.new
          wrapper = subject.new(core, opts)

          wrapper.upsert(THINGS, { key: "flag", version: 3 })
          wrapper.delete(THINGS, "other", 4)

          expect(core.data[THINGS]["flag"]).to eq Interfaces::DataStore::SerializedItemDescriptor.new(
            version: 3, deleted: false, serialized_item: '{"key":"flag","version":3}')
          expect(core.data[THINGS]["other"]).to eq Interfaces::DataStore::SerializedItemDescriptor.new(
            version: 4, deleted: true, serialized_item: '{"key":"other","version":4,"deleted":true}')
        end

        it "gets item" do
          core = MockCore.new
          wrapper = subject.new(core, opts)
          key = "flag"
          itemv1 = { key: key, version: 1 }
          itemv2 = { key: key, version: 2 }

          core.force_set(THINGS, itemv1)
          expect(wrapper.get(THINGS, key)).to eq itemv1

          core.force_set(THINGS, itemv2)
          expect(wrapper.get(THINGS, key)).to eq(cached ? itemv1 : itemv2)  # if cached, we will not see the new underlying value yet
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
          expect(wrapper.get(THINGS, key)).to eq(cached ? nil : itemv2)  # if cached, we will not see the new underlying value yet
        end

        it "treats an item with no serialized data as deleted" do
          core = MockCore.new
          wrapper = subject.new(core, opts)
          core.force_set_descriptor(THINGS, "flag",
            Interfaces::DataStore::SerializedItemDescriptor.new(version: 5, deleted: true, serialized_item: nil))

          expect(wrapper.get(THINGS, "flag")).to be_nil
          expect(wrapper.all(THINGS)).to eq({})
        end

        it "gets missing item" do
          core = MockCore.new
          wrapper = subject.new(core, opts)
          key = "flag"
          item = { key: key, version: 1 }

          expect(wrapper.get(THINGS, key)).to eq nil

          core.force_set(THINGS, item)
          expect(wrapper.get(THINGS, key)).to eq(cached ? nil : item)  # the cache can retain a nil result
        end

        it "gets all items" do
          core = MockCore.new
          wrapper = subject.new(core, opts)
          item1 = { key: "flag1", version: 1 }
          item2 = { key: "flag2", version: 1 }

          core.force_set(THINGS, item1)
          core.force_set(THINGS, item2)
          expect(wrapper.all(THINGS)).to eq({ flag1: item1, flag2: item2 })

          core.force_remove(THINGS, item2[:key])
          expect(wrapper.all(THINGS)).to eq(cached ? { flag1: item1, flag2: item2 } : { flag1: item1 })
        end

        it "gets all items filtering out deleted items" do
          core = MockCore.new
          wrapper = subject.new(core, opts)
          item1 = { key: "flag1", version: 1 }
          item2 = { key: "flag2", version: 1, deleted: true }

          core.force_set(THINGS, item1)
          core.force_set(THINGS, item2)
          expect(wrapper.all(THINGS)).to eq({ flag1: item1 })
        end

        it "upserts item successfully" do
          core = MockCore.new
          wrapper = subject.new(core, opts)
          key = "flag"
          itemv1 = { key: key, version: 1 }
          itemv2 = { key: key, version: 2 }

          expect(wrapper.upsert(THINGS, itemv1)).to be true
          expect(core.stored(THINGS, key)).to eq itemv1

          expect(wrapper.upsert(THINGS, itemv2)).to be true
          expect(core.stored(THINGS, key)).to eq itemv2

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

          expect(wrapper.delete(THINGS, key, 2)).to be true
          expect(core.stored(THINGS, key)).to eq itemv2

          core.force_set(THINGS, itemv3)  # make a change that bypasses the cache

          expect(wrapper.get(THINGS, key)).to eq(cached ? nil : itemv3)
        end

        it "returns false when upsert has a version that is not newer" do
          core = MockCore.new
          wrapper = subject.new(core, opts)
          itemv2 = { key: "flag", version: 2 }
          core.force_set(THINGS, itemv2)

          expect(wrapper.upsert(THINGS, { key: "flag", version: 2 })).to be false
          expect(wrapper.upsert(THINGS, { key: "flag", version: 1 })).to be false
          expect(core.stored(THINGS, "flag")).to eq itemv2
        end

        it "returns false when delete has a version that is not newer" do
          core = MockCore.new
          wrapper = subject.new(core, opts)
          itemv2 = { key: "flag", version: 2 }
          core.force_set(THINGS, itemv2)

          expect(wrapper.delete(THINGS, "flag", 2)).to be false
          expect(core.stored(THINGS, "flag")).to eq itemv2
        end

        it "returns false when the core does not return true from upsert" do
          core = MockCore.new
          core.upsert_result = nil
          wrapper = subject.new(core, opts)

          expect(wrapper.upsert(THINGS, { key: "flag", version: 1 })).to be false
        end

        it "raises an error from init and does not report initialized" do
          core = MockCore.new
          core.error = RuntimeError.new("sorry")
          wrapper = subject.new(core, opts)

          expect { wrapper.init({ THINGS => {} }) }.to raise_error("sorry")
          core.error = nil
          expect(wrapper.initialized?).to be false
        end

        it "raises an error from upsert" do
          core = MockCore.new
          core.error = RuntimeError.new("sorry")
          wrapper = subject.new(core, opts)

          expect { wrapper.upsert(THINGS, { key: "flag", version: 1 }) }.to raise_error("sorry")
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

          wrapper.init({ THINGS => { flag1: item1, flag2: item2 } })
          core.force_remove(THINGS, item1[:key])

          expect(wrapper.get(THINGS, item1[:key])).to eq item1
        end

        it "get all uses values from init" do
          core = MockCore.new
          wrapper = subject.new(core, cached_opts)
          item1 = { key: "flag1", version: 1 }
          item2 = { key: "flag2", version: 1 }

          wrapper.init({ THINGS => { flag1: item1, flag2: item2 } })
          core.force_remove(THINGS, item1[:key])

          expect(wrapper.all(THINGS)).to eq({ flag1: item1, flag2: item2 })
        end

        it "init clears the cache if the core fails" do
          core = MockCore.new
          wrapper = subject.new(core, cached_opts)
          item = { key: "flag", version: 1 }
          wrapper.init({ THINGS => { flag: item } })

          core.error = RuntimeError.new("sorry")
          expect { wrapper.init({ THINGS => {} }) }.to raise_error("sorry")
          core.error = nil

          core.force_remove(THINGS, "flag")
          expect(wrapper.get(THINGS, "flag")).to be_nil
        end

        it "upsert does not change the cache if the core fails" do
          core = MockCore.new
          wrapper = subject.new(core, cached_opts)
          itemv1 = { key: "flag", version: 1 }
          wrapper.upsert(THINGS, itemv1)

          core.error = RuntimeError.new("sorry")
          expect { wrapper.upsert(THINGS, { key: "flag", version: 2 }) }.to raise_error("sorry")
          core.error = nil

          expect(wrapper.get(THINGS, "flag")).to eq itemv1
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
          expect(core.stored(THINGS, key)).to eq itemv2

          wrapper.upsert(THINGS, itemv1)
          expect(core.stored(THINGS, key)).to eq itemv2  # value in store remains the same

          itemv3 = { key: key, version: 3 }
          core.force_set(THINGS, itemv3)  # bypasses cache so we can verify that itemv2 is in the cache
          expect(wrapper.get(THINGS, key)).to eq itemv2
        end

        it "upsert caches the item from the store if unsuccessful" do
          core = MockCore.new
          wrapper = subject.new(core, cached_opts)
          key = "flag"
          itemv1 = { key: key, version: 1 }
          itemv3 = { key: key, version: 3 }

          wrapper.upsert(THINGS, itemv1)
          core.force_set(THINGS, itemv3)  # another process writes a newer version

          expect(wrapper.upsert(THINGS, { key: key, version: 2 })).to be false
          core.force_remove(THINGS, key)  # bypasses cache so we can verify that itemv3 is in the cache
          expect(wrapper.get(THINGS, key)).to eq itemv3
        end

        it "upsert keeps the cached item if the store read fails after an unsuccessful write" do
          core = MockCore.new
          wrapper = subject.new(core, cached_opts)
          itemv2 = { key: "flag", version: 2 }
          wrapper.upsert(THINGS, itemv2)

          core.get_error = RuntimeError.new("sorry")
          expect(wrapper.upsert(THINGS, { key: "flag", version: 1 })).to be false
          core.get_error = nil

          core.force_set(THINGS, { key: "flag", version: 3 })
          expect(wrapper.get(THINGS, "flag")).to eq itemv2
        end

        it "upsert drops the cached list of all items" do
          core = MockCore.new
          wrapper = subject.new(core, cached_opts)
          item1 = { key: "flag1", version: 1 }
          item2 = { key: "flag2", version: 1 }
          wrapper.init({ THINGS => { flag1: item1 } })
          expect(wrapper.all(THINGS)).to eq({ flag1: item1 })

          wrapper.upsert(THINGS, item2)
          expect(wrapper.all(THINGS)).to eq({ flag1: item1, flag2: item2 })
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

      describe "#disable_cache" do
        it "releases the cache so subsequent reads bypass it" do
          core = MockCore.new
          wrapper = subject.new(core, { expiration: 30 })
          item = { key: "flag", version: 1 }
          core.force_set(THINGS, item)

          # prime the cache
          expect(wrapper.get(THINGS, "flag")).to eq item

          # change underlying value; cached value should still be returned
          itemv2 = { key: "flag", version: 2 }
          core.force_set(THINGS, itemv2)
          expect(wrapper.get(THINGS, "flag")).to eq item

          wrapper.disable_cache

          # after disable, reads see the underlying value
          expect(wrapper.get(THINGS, "flag")).to eq itemv2
        end

        it "is a safe no-op when caching is disabled at config time" do
          wrapper = subject.new(MockCore.new, { expiration: 0 })
          expect { wrapper.disable_cache }.not_to raise_error
        end

        it "is idempotent" do
          wrapper = subject.new(MockCore.new, { expiration: 30 })
          wrapper.disable_cache
          expect { wrapper.disable_cache }.not_to raise_error
        end

        it "does not repopulate the cache on upsert after disable" do
          core = MockCore.new
          wrapper = subject.new(core, { expiration: 30 })
          wrapper.init({ THINGS => {} })
          wrapper.disable_cache

          item = { key: "flag", version: 1 }
          wrapper.upsert(THINGS, item)

          # mutate underlying value; if a read came from cache it would still see the upserted item
          itemv2 = { key: "flag", version: 2 }
          core.force_set(THINGS, itemv2)
          expect(wrapper.get(THINGS, "flag")).to eq itemv2
        end

        it "does not repopulate the cache on get after disable" do
          core = MockCore.new
          wrapper = subject.new(core, { expiration: 30 })
          wrapper.disable_cache

          item = { key: "flag", version: 1 }
          core.force_set(THINGS, item)
          expect(wrapper.get(THINGS, "flag")).to eq item

          itemv2 = { key: "flag", version: 2 }
          core.force_set(THINGS, itemv2)
          expect(wrapper.get(THINGS, "flag")).to eq itemv2
        end
      end

      describe Interfaces::PersistentDataStore do
        it "does not hide a method that a store inherits from a superclass" do
          base = Class.new do
            def stop
              :stopped
            end
          end
          store = Class.new(base) { include Interfaces::PersistentDataStore }.new

          expect(store.stop).to eq :stopped
        end

        it "does not supply a method that a store does not implement" do
          store = Class.new { include Interfaces::PersistentDataStore }.new

          expect { store.stop }.to raise_error(NoMethodError)
        end
      end

      #
      # A store core that keeps serialized items in memory. Like Redis, it does not keep the version
      # apart from the serialized item.
      #
      class MockCore
        include Interfaces::PersistentDataStore

        def initialize
          @data = {}
          @inited = false
          @inited_query_count = 0
          @upsert_result = :default
        end

        attr_reader :data
        attr_reader :inited_query_count
        attr_accessor :inited, :error, :get_error, :upsert_result

        def force_set(kind, item)
          force_set_descriptor(kind, item[:key], Interfaces::DataStore::SerializedItemDescriptor.new(
            version: 0, deleted: false, serialized_item: kind.serialize(item)))
        end

        def force_set_descriptor(kind, key, descriptor)
          @data[kind] = {} unless @data.has_key?(kind)
          @data[kind][key] = descriptor
        end

        def force_remove(kind, key)
          @data[kind].delete(key) if @data.has_key?(kind)
        end

        def stored(kind, key)
          kind.deserialize(@data[kind][key].serialized_item)
        end

        def init(all_data)
          raise @error unless @error.nil?
          @data = all_data.to_h { |kind, items| [kind, items.transform_keys(&:to_s)] }
          @inited = true
        end

        def get(kind, key)
          raise @get_error unless @get_error.nil?
          items = @data[kind]
          items.nil? ? nil : items[key.to_s]
        end

        def get_all(kind)
          @data[kind] || {}
        end

        def upsert(kind, key, item)
          raise @error unless @error.nil?
          return @upsert_result unless @upsert_result == :default
          @data[kind] = {} unless @data.has_key?(kind)
          old = @data[kind][key.to_s]
          return false if !old.nil? && kind.deserialize(old.serialized_item)[:version] >= item.version
          @data[kind][key.to_s] = item
          true
        end

        def initialized?
          @inited_query_count = @inited_query_count + 1
          @inited
        end

        def available?
          true
        end

        def stop
        end
      end
    end
  end
end
