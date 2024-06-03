require "ldclient-rb/context"
require "json"

module LaunchDarkly
  describe LDContext do
    subject { LDContext }

    it "returns nil for any value if invalid" do
      result = subject.create({ key: "", kind: "user", name: "testing" })

      expect(result.valid?).to be false

      expect(result.key).to be_nil
      expect(result.get_value(:key)).to be_nil

      expect(result.kind).to be_nil
      expect(result.get_value(:kind)).to be_nil

      expect(result.get_value(:name)).to be_nil
    end

    describe "context construction" do
      describe "single kind contexts" do
        it "can be created using the new format" do
          context = {
            key: "launchdarkly",
            kind: "org",
            address: {
              street: "1999 Harrison St Suite 1100",
              city: "Oakland",
              state: "CA",
              zip: "94612",
            },
          }
          result = subject.create(context)
          expect(result).to be_a(LDContext)
          expect(result.key).to eq("launchdarkly")
          expect(result.kind).to eq("org")
          expect(result.valid?).to be true
        end

        it "do not allow empty strings or nil values for keys" do
          expect(subject.create({ kind: "user", key: "" }).valid?).to be false
          expect(subject.create({ kind: "user", key: nil }).valid?).to be false
          expect(subject.create({ kind: "user" }).valid?).to be false
        end

        it "does not allow reserved names or empty values for kind" do
          expect(subject.create({ kind: true, key: "key" }).valid?).to be false
          expect(subject.create({ kind: "", key: "key" }).valid?).to be false
          expect(subject.create({ kind: "kind", key: "key" }).valid?).to be false
          expect(subject.create({ kind: "multi", key: "key" }).valid?).to be false
        end

        it "anonymous is required to be a boolean or nil" do
          expect(subject.create({ key: "key", kind: "user" }).valid?).to be true
          expect(subject.create({ key: "key", kind: "user", anonymous: nil }).valid?).to be false
          expect(subject.create({ key: "key", kind: "user", anonymous: true }).valid?).to be true
          expect(subject.create({ key: "key", kind: "user", anonymous: false }).valid?).to be true
          expect(subject.create({ key: "key", kind: "user", anonymous: 0 }).valid?).to be false
        end

        it "name is required to be a string or nil" do
          expect(subject.create({ key: "key", kind: "user" }).valid?).to be true
          expect(subject.create({ key: "key", kind: "user", name: "My Name" }).valid?).to be true
          expect(subject.create({ key: "key", kind: "user", name: 0 }).valid?).to be false
        end

        it "require privateAttributes to be an array" do
          context = {
            key: "user-key",
            kind: "user",
            _meta: {
              privateAttributes: "not an array",
            },
          }
          expect(subject.create(context).valid?).to be false
        end

        it "creates the correct fully qualified key" do
          expect(subject.create({ key: "user-key", kind: "user" }).fully_qualified_key).to eq("user-key")
          expect(subject.create({ key: "org-key", kind: "org" }).fully_qualified_key).to eq("org:org-key")
        end
      end

      describe "multi-kind contexts" do
        it "can be created from single kind contexts" do
          user_context = subject.create({ key: "user-key", kind: "user" })
          org_context = subject.create({ key: "org-key", kind: "org" })
          multi_context = subject.create_multi([user_context, org_context])

          expect(multi_context).to be_a(LDContext)
          expect(multi_context.key).to be_nil
          expect(multi_context.kind).to eq("multi")
          expect(multi_context.valid?).to be true
        end

        it "can be created from a hash" do
          data = { kind: "multi", user_context: { key: "user-key"}, org: { key: "org-key"}}
          multi_context = subject.create(data)

          expect(multi_context).to be_a(LDContext)
          expect(multi_context.key).to be_nil
          expect(multi_context.kind).to eq(LDContext::KIND_MULTI)
          expect(multi_context.valid?).to be true
        end

        it "will return the single kind context if only one is provided" do
          user_context = subject.create({ kind: 'user', key: "user-key" })
          multi_context = subject.create_multi([user_context])

          expect(multi_context).to be_a(LDContext)
          expect(multi_context).to eq(user_context)
        end

        it "cannot include another multi-kind context" do
          user_context = subject.create({ key: "user-key" })
          org_context = subject.create({ key: "org-key", kind: "org" })
          embedded_multi_context = subject.create_multi([user_context, org_context])
          multi_context = subject.create_multi([embedded_multi_context])

          expect(multi_context).to be_a(LDContext)
          expect(multi_context.valid?).to be false
        end

        it "are invalid if no contexts are provided" do
          multi_context = subject.create_multi([])
          expect(multi_context.valid?).to be false
        end

        it "are invalid if a single context is invalid" do
          valid_context = subject.create({ kind: "user", key: "user-key" })
          invalid_context = subject.create({ kind: "org" })
          multi_context = subject.create_multi([valid_context, invalid_context])

          expect(valid_context.valid?).to be true
          expect(invalid_context.valid?).to be false
          expect(multi_context.valid?).to be false
        end

        it "creates the correct fully qualified key" do
          user_context = subject.create({ key: "a-user-key", kind: 'user' })
          org_context = subject.create({ key: "b-org-key", kind: "org" })
          user_first = subject.create_multi([user_context, org_context])
          org_first = subject.create_multi([org_context, user_context])

          # Verify we are sorting contexts by kind when generating the canonical key
          expect(user_first.fully_qualified_key).to eq("org:b-org-key:user:a-user-key")
          expect(org_first.fully_qualified_key).to eq("org:b-org-key:user:a-user-key")
        end
      end

      describe "converts back to JSON format" do
        it "single kind contexts" do
          contextHash = {
            key: "launchdarkly",
            kind: "org",
            address: {
              street: "1999 Harrison St Suite 1100",
              city: "Oakland",
              state: "CA",
              zip: "94612",
              _meta: {
                privateAttributes: ["city"],
              },
            },
          }
          context = subject.create(contextHash)
          contextJson = context.to_json
          backToHash = JSON.parse(contextJson, symbolize_names: true)

          expect(backToHash).to eq(contextHash)
        end

        it "multi kind contexts" do
          contextHash = {
            kind: "multi",
            "org": {
              key: "launchdarkly",
              address: {
                street: "1999 Harrison St Suite 1100",
                city: "Oakland",
                state: "CA",
                zip: "94612",
              },
              _meta: {
                privateAttributes: ["address/city"],
              },
            },
            "user": {
              key: "user-key",
              name: "Ruby",
              anonymous: true,
            },
          }
          context = subject.create(contextHash)
          contextJson = context.to_json
          backToHash = JSON.parse(contextJson, symbolize_names: true)

          expect(backToHash).to eq(contextHash)
        end

        it "invalid context returns error" do
          context = subject.create({ key: "", kind: "user", name: "testing" })
          expect(context.valid?).to be false
          expect(context.to_h).to eq({ error: "context key must not be empty" })
          expect(context.to_json).to eq({ error: "context key must not be empty" }.to_json)
        end
      end
    end

    describe "context counts" do
      it "invalid contexts have a size of 0" do
        context = subject.create({})

        expect(context.valid?).to be false
        expect(context.individual_context_count).to eq(0)
      end

      it "individual contexts have a size of 1" do
        context = subject.create({ kind: "user", key: "user-key" })
        expect(context.individual_context_count).to eq(1)
      end

      it "multi-kind contexts have a size equal to the single-kind contexts" do
        user_context = subject.create({ key: "user-key", kind: "user" })
        org_context = subject.create({ key: "org-key", kind: "org" })
        multi_context = subject.create_multi([user_context, org_context])

        expect(multi_context.individual_context_count).to eq(2)
      end
    end

    describe "retrieving specific contexts" do
      it "invalid contexts always return nil" do
        context = subject.create({kind: "user"})

        expect(context.valid?).to be false
        expect(context.individual_context(-1)).to be_nil
        expect(context.individual_context(0)).to be_nil
        expect(context.individual_context(1)).to be_nil

        expect(context.individual_context("user")).to be_nil
      end

      it "single contexts can retrieve themselves" do
        context = subject.create({key: "user-key", kind: "user"})

        expect(context.valid?).to be true
        expect(context.individual_context(-1)).to be_nil
        expect(context.individual_context(0)).to eq(context)
        expect(context.individual_context(1)).to be_nil

        expect(context.individual_context("user")).to eq(context)
        expect(context.individual_context("org")).to be_nil
      end

      it "multi-kind contexts can return nested contexts" do
        user_context = subject.create({ key: "user-key", kind: "user" })
        org_context = subject.create({ key: "org-key", kind: "org" })
        multi_context = subject.create_multi([user_context, org_context])

        expect(multi_context.valid?).to be true
        expect(multi_context.individual_context(-1)).to be_nil
        expect(multi_context.individual_context(0)).to eq(user_context)
        expect(multi_context.individual_context(1)).to eq(org_context)

        expect(multi_context.individual_context("user")).to eq(user_context)
        expect(multi_context.individual_context("org")).to eq(org_context)
      end
    end

    describe "hash-like behavior" do
      it "multi-kind contexts return nested contexts" do
        user_context = subject.create({ key: "user-key", kind: "user" })
        org_context = subject.create({ key: "org-key", kind: "org" })
        multi_context = subject.create_multi([user_context, org_context])

        expect(multi_context.valid?).to be true
        expect(multi_context["user"]).to eq(user_context)
        expect(multi_context["org"]).to eq(org_context)
        expect(multi_context["no-such-type"]).to be_nil
      end

      describe "single-kind contexts" do
        it "can retrieve the correct simple attribute value" do
          context = subject.create({ key: "my-key", kind: "org", name: "x", :"my-attr" => "y", :"/starts-with-slash" => "z" })

          expect(context["kind"]).to eq("org")
          expect(context["key"]).to eq("my-key")
          expect(context["name"]).to eq("x")
          expect(context["my-attr"]).to eq("y")
          expect(context["/starts-with-slash"]).to eq("z")
          expect(context["a-value-that-is-not-set"]).to be_nil
        end

        it "cannot query subpath/elements" do
          object_value = { a: 1 }
          array_value = [1]

          context = subject.create({ key: "my-key", kind: "org", :"obj-attr" => object_value, :"array-attr" => array_value })
          expect(context["obj-attr"]).to eq(object_value)
          expect(context[:"array-attr"]).to eq(array_value)

          expect(context[:"/obj-attr/a"]).to be_nil
          expect(context[:"/array-attr/0"]).to be_nil
        end
      end
    end

    describe "value retrieval" do
      describe "supports simple attribute retrieval" do
        it "can retrieve the correct simple attribute value" do
          context = subject.create({ key: "my-key", kind: "org", name: "x", :"my-attr" => "y", :"/starts-with-slash" => "z" })

          expect(context.get_value("kind")).to eq("org")
          expect(context.get_value("key")).to eq("my-key")
          expect(context.get_value("name")).to eq("x")
          expect(context.get_value("my-attr")).to eq("y")
          expect(context.get_value("/starts-with-slash")).to eq("z")
        end

        it "does not allow querying subpath/elements" do
          object_value = { a: 1 }
          array_value = [1]

          context = subject.create({ key: "my-key", kind: "org", :"obj-attr" => object_value, :"array-attr" => array_value })
          expect(context.get_value("obj-attr")).to eq(object_value)
          expect(context.get_value(:"array-attr")).to eq(array_value)

          expect(context.get_value(:"/obj-attr/a")).to be_nil
          expect(context.get_value(:"/array-attr/0")).to be_nil
        end
      end

      describe "supports retrieval" do
        it "with only support kind for multi-kind contexts" do
          user_context = subject.create({ key: 'user', kind: 'user', name: 'Ruby', anonymous: true })
          org_context = subject.create({ key: 'ld', kind: 'org', name: 'LaunchDarkly', anonymous: false })

          multi_context = subject.create_multi([user_context, org_context])

          [
            ['kind', eq('multi')],
            ['key', be_nil],
            ['name', be_nil],
            ['anonymous', be_nil],
          ].each do |(reference, matcher)|
            expect(multi_context.get_value_for_reference(Reference.create(reference))).to matcher
          end
        end

        it "with basic attributes" do
          org_context = subject.create({ key: 'ld', kind: 'org', name: 'LaunchDarkly', anonymous: true, _meta: { privateAttributes: ['name'] } })

          [
            # Simple top level attributes are accessible
            ['kind', eq('user'), eq('org')],
            ['key', eq('user'), eq('ld')],
            ['name', eq('Ruby'), eq('LaunchDarkly')],
            ['anonymous', eq(false), eq(true)],

            # Cannot access meta data
            ['privateAttributeNames', be_nil, be_nil],
            ['privateAttributes', be_nil, be_nil],
          ].each do |(reference, user_matcher, org_matcher)|
            ref = Reference.create(reference)
            expect(org_context.get_value_for_reference(ref)).to org_matcher
          end
        end

        it "with complex attributes" do
          address = { city: "Oakland", state: "CA", zip: 94612 }
          tags = ["LaunchDarkly", "Feature Flags"]
          nested = { upper: { middle: { name: "Middle Level", inner: { levels: [0, 1, 2] } }, name: "Upper Level" } }

          org_context = subject.create({ key: 'ld', kind: 'org', name: 'LaunchDarkly', anonymous: true, address: address, tags: tags, nested: nested })

          [
            # Simple top level attributes are accessible
            ['/address', eq(address)],
            ['/address/city', eq('Oakland')],

            ['/tags', eq(tags)],

            ['/nested/upper/name', eq('Upper Level')],
            ['/nested/upper/middle/name', eq('Middle Level')],
            ['/nested/upper/middle/inner/levels', eq([0, 1, 2])],
          ].each do |(reference, matcher)|
            ref = Reference.create(reference)
            expect(org_context.get_value_for_reference(ref)).to matcher
          end
        end
      end
    end

    describe "equality comparisons" do
      it "wrong types are not equal" do
        context = subject.create({ key: 'context-key', kind: 'user' })
        expect(context).to_not eq(true)
        expect(context).to_not eq(3)
      end

      it "single-kind context can compare with hash" do
        hash = { key: 'context-key', kind: 'user', name: 'Example name', groups: ['test', 'it', 'here'], address: {street: '123 Easy St', city: 'Every Town'},
            _meta: { privateAttributes: ['name', 'out of order attribute'] }
          }
        context = subject.create(hash)
        expect(context).to eq(hash)
      end

      it "multi-kind context can compare with hash" do
        hash = {
          kind: "multi",
          org: { key: 'org-key', kind: 'org' },
          user: { key: 'user-key', kind: 'user' },
          device: { key: 'device-key', kind: 'device' },
        }
        org_context = subject.create(hash[:org])
        user_context = subject.create(hash[:user])
        device_context = subject.create(hash[:device])
        context = subject.create(hash)

        expect(context).to eq(hash)
        expect(context["org"]).to eq(hash[:org])
        expect(context["user"]).to eq(hash[:user])
        expect(context["device"]).to eq(hash[:device])
      end

      it "single kind contexts are equal" do
        original_context = subject.create(
          { key: 'context-key', kind: 'user', name: 'Example name', groups: ['test', 'it', 'here'], address: {street: '123 Easy St', city: 'Every Town'},
            _meta: { privateAttributes: ['name', 'out of order attribute'] }
          })
        duplicate_context = subject.create(
          { key: 'context-key', kind: 'user', name: 'Example name', groups: ['test', 'it', 'here'], address: {street: '123 Easy St', city: 'Every Town'},
            _meta: { privateAttributes: ['out of order attribute', 'name'] }
          })
        expect(original_context).to eq(duplicate_context)
      end

      it "multi kind contexts are equal" do
        org_context = subject.create({ key: 'org-key', kind: 'org' })
        user_context = subject.create({ key: 'user-key', kind: 'user' })
        device_context = subject.create({ key: 'device-key', kind: 'device' })

        original_context = subject.create_multi([org_context, user_context])
        duplicate_context = subject.create_multi([user_context, org_context])

        expect(original_context).to eq(duplicate_context)

        superset_context = subject.create_multi([org_context, user_context, device_context])
        expect(superset_context).not_to eq(duplicate_context)
      end

      it "mixed size contexts are not equal" do
        org_context = subject.create({ key: 'org-key', kind: 'org' })
        user_context = subject.create({ key: 'user-key', kind: 'user' })

        flattened_multi = subject.create_multi([org_context])

        expect(flattened_multi).to eq(org_context)

        multi = subject.create_multi([org_context, user_context])
        expect(multi).not_to eq(org_context)
        expect(multi).not_to eq(user_context)
      end

      it "failed contexts can be equal" do
        invalid_hash = subject.create(true)
        invalid_kind = subject.create({ kind: 'this is not valid' })
        invalid_key = subject.create({ key: nil })
        invalid_name = subject.create({ key: 'user-key', name: true })
        invalid_anonymous = subject.create({ key: 'user-key', anonymous: 'this is no boolean' })
        invalid_private_attributes = subject.create({ key: 'user-key', _meta: { privateAttributes: 'this is no array' }})

        expect(invalid_hash).not_to eq(invalid_kind)
        expect(invalid_hash).not_to eq(invalid_key)
        expect(invalid_hash).not_to eq(invalid_name)
        expect(invalid_hash).not_to eq(invalid_anonymous)
        expect(invalid_hash).not_to eq(invalid_private_attributes)

        expect(invalid_hash).to eq(subject.create(true))
        expect(invalid_kind).to eq(subject.create({ kind: 'this is not valid' }))
        expect(invalid_key).to eq(subject.create({ key: nil }))
        expect(invalid_name).to eq(subject.create({ key: 'user-key', name: true }))
        expect(invalid_anonymous).to eq(subject.create({ key: 'user-key', anonymous: 'this is no boolean' }))
        expect(invalid_private_attributes).to eq(subject.create({ key: 'user-key', _meta: { privateAttributes: 'this is no array' }}))
      end
    end
  end
end
