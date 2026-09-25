# frozen_string_literal: true

require "spec_helper"
require "model_builders"
require "ldclient-rb/impl/overrides"
require "ldclient-rb/impl/broadcaster"
require "ldclient-rb/impl/data_store/in_memory_feature_store"

module LaunchDarkly
  module Impl
    module Overrides
      describe Sink do
        # The synchronous executor delivers notifications inside broadcast, so the tests can read
        # them right after set_overrides returns.
        let(:broadcaster) { Broadcaster.new(SynchronousExecutor.new, $null_log) }
        let(:base) { DataStore::InMemoryFeatureStoreV2.new($null_log) }
        let(:layer) { Layer.new }
        subject(:sink) { Sink.new(layer, base, broadcaster, $null_log) }

        def flag(key, value, version: 1, prereqs: [], segment: nil)
          data = {
            key: key, version: version, on: true, offVariation: 0, fallthrough: { variation: 0 }, variations: [value],
            prerequisites: prereqs.map { |p| { key: p, variation: 0 } }
          }
          if segment
            data[:rules] = [{ id: "r", variation: 0, clauses: [{ attribute: "", op: "segmentMatch", values: [segment] }] }]
          end
          Flags.from_hash(data)
        end

        def segment(key, version: 1, nested: nil)
          data = { key: key, version: version, included: ["user"] }
          data[:rules] = [{ clauses: [{ attribute: "", op: "segmentMatch", values: [nested] }] }] if nested
          Segments.from_hash(data)
        end

        def listen
          listener = ListenerSpy.new
          broadcaster.add_listener(listener)
          listener
        end

        def changed_keys(listener)
          listener.statuses.map(&:key).sort
        end

        it "is an override sink" do
          expect(sink).to be_a(Interfaces::Overrides::OverrideSink)
        end

        it "replaces the layer with marked entries" do
          sink.set_overrides([flag("a", "x")], [segment("s")])

          expect(layer.get(DataStore::FEATURES, "a").override?).to be true
          expect(layer.get(DataStore::FEATURES, "a").variations).to eq ["x"]
          expect(layer.get(DataStore::SEGMENTS, "s").override?).to be true
        end

        it "accepts definitions given as hashes" do
          sink.set_overrides([{ key: "a", version: 1, on: false, offVariation: 0, variations: ["x"] }],
            [{ key: "s", version: 1, included: ["user"] }])

          expect(layer.get(DataStore::FEATURES, "a")).to be_a(Model::FeatureFlag)
          expect(layer.get(DataStore::FEATURES, "a").variations).to eq ["x"]
          expect(layer.get(DataStore::SEGMENTS, "s")).to be_a(Model::Segment)
        end

        it "accepts nil and empty collections and clears the layer" do
          sink.set_overrides([flag("a", "x")], [segment("s")])
          sink.set_overrides(nil, nil)

          expect(layer.empty?).to be true
        end

        it "rejects an entry without a key" do
          expect { sink.set_overrides([{ version: 1, on: false }], []) }.to raise_error(ArgumentError, /has no key/)
          expect { sink.set_overrides([], [{ key: "", version: 1 }]) }.to raise_error(ArgumentError, /has no key/)
        end

        it "does not notify when nothing is listening but still replaces the layer" do
          expect(broadcaster).not_to receive(:broadcast)

          sink.set_overrides([flag("a", "x")], [])

          expect(layer.get(DataStore::FEATURES, "a")).not_to be_nil
        end

        it "notifies the flags whose override entries were added" do
          listener = listen

          sink.set_overrides([flag("a", "x"), flag("b", "y")], [])

          expect(changed_keys(listener)).to eq %w[a b]
        end

        it "notifies an added override even when it matches the LaunchDarkly data" do
          base.set_basis({ DataStore::FEATURES => { a: flag("a", "x").data }, DataStore::SEGMENTS => {} })
          listener = listen

          sink.set_overrides([flag("a", "x")], [])

          expect(changed_keys(listener)).to eq %w[a]
        end

        it "notifies the flags whose override entries were removed" do
          sink.set_overrides([flag("a", "x"), flag("b", "y")], [])
          listener = listen

          sink.set_overrides([flag("b", "y")], [])

          expect(changed_keys(listener)).to eq %w[a]
        end

        it "notifies a flag whose override entry changed and not one that stayed the same" do
          sink.set_overrides([flag("a", "x"), flag("b", "y")], [])
          listener = listen

          sink.set_overrides([flag("a", "x2"), flag("b", "y")], [])

          expect(changed_keys(listener)).to eq %w[a]
        end

        it "treats a version change alone as a change" do
          sink.set_overrides([flag("a", "x", version: 1)], [])
          listener = listen

          sink.set_overrides([flag("a", "x", version: 2)], [])

          expect(changed_keys(listener)).to eq %w[a]
        end

        it "does not notify when the snapshot is identical" do
          sink.set_overrides([flag("a", "x")], [segment("s")])
          listener = listen

          sink.set_overrides([flag("a", "x")], [segment("s")])

          expect(changed_keys(listener)).to eq []
        end

        it "notifies every override that an empty snapshot removes" do
          sink.set_overrides([flag("a", "x"), flag("b", "y")], [])
          listener = listen

          sink.set_overrides([], [])

          expect(changed_keys(listener)).to eq %w[a b]
        end

        it "notifies LaunchDarkly flags that depend on an overridden prerequisite" do
          base.set_basis({
            DataStore::FEATURES => {
              prereq: flag("prereq", "p").data,
              top: flag("top", "t", prereqs: ["prereq"]).data,
              higher: flag("higher", "h", prereqs: ["top"]).data,
              unrelated: flag("unrelated", "u").data,
            },
            DataStore::SEGMENTS => {},
          })
          listener = listen

          sink.set_overrides([flag("prereq", "p2")], [])

          expect(changed_keys(listener)).to eq %w[higher prereq top]
        end

        it "notifies flags whose rules reference an overridden segment, including through a nested segment" do
          base.set_basis({
            DataStore::FEATURES => {
              direct: flag("direct", "d", segment: "s").data,
              nested: flag("nested", "n", segment: "outer").data,
              unrelated: flag("unrelated", "u").data,
            },
            DataStore::SEGMENTS => { s: segment("s").data, outer: segment("outer", nested: "s").data },
          })
          listener = listen

          sink.set_overrides([], [segment("s", version: 2)])

          expect(changed_keys(listener)).to eq %w[direct nested]
        end

        it "uses the old merged view as well as the new one to find dependents" do
          # The base can change between the two snapshots. A flag that depended on a removed override
          # only in the old view is still notified.
          y = flag("y", "1")
          previous = { DataStore::FEATURES => { y: y.as_override }, DataStore::SEGMENTS => {} }
          current = { DataStore::FEATURES => {}, DataStore::SEGMENTS => {} }
          old_view = { DataStore::FEATURES => { y: y, x: flag("x", "a", prereqs: ["y"]) }, DataStore::SEGMENTS => {} }
          new_view = { DataStore::FEATURES => { x: flag("x", "a") }, DataStore::SEGMENTS => {} }

          expect(Sink.affected_flag_keys(previous, current, old_view, new_view).sort).to eq %w[x y]
        end

        it "notifies dependents after an override that rewired prerequisites is removed" do
          # The override of "top" replaced its prerequisite edge. Removing the override restores the
          # LaunchDarkly definition, whose prerequisite is "ld-prereq". "top" changes either way, and
          # the flags that depend on "top" are notified with it.
          base.set_basis({
            DataStore::FEATURES => {
              top: flag("top", "t", prereqs: ["ld-prereq"]).data,
              "ld-prereq": flag("ld-prereq", "l").data,
              "override-prereq": flag("override-prereq", "o").data,
              dependent: flag("dependent", "d", prereqs: ["top"]).data,
            },
            DataStore::SEGMENTS => {},
          })
          sink.set_overrides([flag("top", "t2", prereqs: ["override-prereq"])], [])
          listener = listen

          sink.set_overrides([], [])

          expect(changed_keys(listener)).to eq %w[dependent top]
        end

        it "notifies dependents through prerequisite edges that only the override introduces" do
          base.set_basis({
            DataStore::FEATURES => {
              top: flag("top", "t").data,
              other: flag("other", "o").data,
              dependent: flag("dependent", "d", prereqs: ["top"]).data,
            },
            DataStore::SEGMENTS => {},
          })
          # The override makes "top" depend on "other". A later change to "other" then affects "top"
          # and "dependent" through the new view.
          sink.set_overrides([flag("top", "t2", prereqs: ["other"])], [])
          listener = listen

          sink.set_overrides([flag("top", "t2", prereqs: ["other"]), flag("other", "o2")], [])

          expect(changed_keys(listener)).to eq %w[dependent other top]
        end

        it "still notifies the directly changed keys when the base store cannot be read" do
          failing = double("base")
          allow(failing).to receive(:all).and_raise(RuntimeError, "store down")
          sink = Sink.new(layer, failing, broadcaster, $null_log)
          listener = listen

          sink.set_overrides([flag("a", "x")], [])

          expect(changed_keys(listener)).to eq %w[a]
          expect(layer.get(DataStore::FEATURES, "a")).not_to be_nil
        end

        it "serializes overlapping updates so the layer always holds one whole snapshot" do
          listener = listen
          threads = Array.new(4) do |i|
            Thread.new do
              20.times do |n|
                sink.set_overrides([flag("f#{i}", "v#{n}")], [])
              end
            end
          end
          threads.each(&:join)

          contents = layer.all(DataStore::FEATURES)
          expect(contents.length).to eq 1
          expect(listener.statuses).not_to be_empty
        end
      end
    end
  end
end
