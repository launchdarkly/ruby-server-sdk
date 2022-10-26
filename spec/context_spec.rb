require "ldclient-rb/context"

describe LaunchDarkly::LDContext do
  subject { LaunchDarkly::LDContext }

  it "returns nil for any value if invalid" do
    result = subject.create({ key: "", kind: "user", name: "testing" })

    expect(result.valid?).to be_falsey

    expect(result.key).to be_nil
    expect(result.get_value(:key)).to be_nil

    expect(result.kind).to be_nil
    expect(result.get_value(:kind)).to be_nil

    expect(result.get_value(:name)).to be_nil
  end

  describe "context construction" do
    describe "legacy users contexts" do
      it "can be created using the legacy user format" do
        context = {
          key: "user-key",
          custom: {
            address: {
              street: "123 Main St.",
              city: "Every City",
              state: "XX",
            },
          },
        }
        result = subject.create(context)
        expect(result).to be_a(LaunchDarkly::LDContext)
        expect(result.key).to eq("user-key")
        expect(result.kind).to eq("user")
        expect(result.valid?).to be_truthy
      end

      it "allows an empty string for a key, but it cannot be missing or nil" do
        expect(subject.create({ key: "" }).valid?).to be_truthy
        expect(subject.create({ key: nil }).valid?).to be_falsey
        expect(subject.create({}).valid?).to be_falsey
      end

      it "anonymous is required to be a boolean or nil" do
        expect(subject.create({ key: "" }).valid?).to be_truthy
        expect(subject.create({ key: "", anonymous: true }).valid?).to be_truthy
        expect(subject.create({ key: "", anonymous: false }).valid?).to be_truthy
        expect(subject.create({ key: "", anonymous: 0 }).valid?).to be_falsey
      end

      it "name is required to be a string or nil" do
        expect(subject.create({ key: "" }).valid?).to be_truthy
        expect(subject.create({ key: "", name: "My Name" }).valid?).to be_truthy
        expect(subject.create({ key: "", name: 0 }).valid?).to be_falsey
      end

      it "requires privateAttributeNames to be an array" do
        context = {
          key: "user-key",
          privateAttributeNames: "not an array",
        }
        expect(subject.create(context).valid?).to be_falsey
      end

      it "overwrite custom properties with built-ins when collisons occur" do
        context = {
          key: "user-key",
          secondary: "secondary",
          avatar: "avatar",
          custom: {
            secondary: "custom secondary",
            avatar: "custom avatar",
          },
        }

        result = subject.create(context)
        expect(result.get_value(:secondary)).to eq("secondary")
        expect(result.get_value(:avatar)).to eq("avatar")
      end
    end

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
        expect(result).to be_a(LaunchDarkly::LDContext)
        expect(result.key).to eq("launchdarkly")
        expect(result.kind).to eq("org")
        expect(result.valid?).to be_truthy
      end

      it "do not allow empty strings or nil values for keys" do
        expect(subject.create({ kind: "user", key: "" }).valid?).to be_falsey
        expect(subject.create({ kind: "user", key: nil }).valid?).to be_falsey
        expect(subject.create({ kind: "user" }).valid?).to be_falsey
      end

      it "anonymous is required to be a boolean or nil" do
        expect(subject.create({ key: "key", kind: "user" }).valid?).to be_truthy
        expect(subject.create({ key: "key", kind: "user", anonymous: true }).valid?).to be_truthy
        expect(subject.create({ key: "key", kind: "user", anonymous: false }).valid?).to be_truthy
        expect(subject.create({ key: "key", kind: "user", anonymous: 0 }).valid?).to be_falsey
      end

      it "name is required to be a string or nil" do
        expect(subject.create({ key: "key", kind: "user" }).valid?).to be_truthy
        expect(subject.create({ key: "key", kind: "user", name: "My Name" }).valid?).to be_truthy
        expect(subject.create({ key: "key", kind: "user", name: 0 }).valid?).to be_falsey
      end

      it "require privateAttributes to be an array" do
        context = {
          key: "user-key",
          kind: "user",
          _meta: {
            privateAttributes: "not an array",
          },
        }
        expect(subject.create(context).valid?).to be_falsey
      end

      it "overwrite secondary property if also specified at top level" do
        context = {
          key: "user-key",
          kind: "user",
          secondary: "invalid secondary",
          _meta: {
            secondary: "real secondary",
          },
        }

        result = subject.create(context)
        expect(result.get_value(:secondary)).to eq("real secondary")
      end
    end

    describe "multi-kind contexts" do
      it "can be created from single kind contexts" do
        user_context = subject.create({ key: "user-key" })
        org_context = subject.create({ key: "org-key", kind: "org" })
        multi_context = subject.create_multi([user_context, org_context])

        expect(multi_context).to be_a(LaunchDarkly::LDContext)
        expect(multi_context.key).to be_nil
        expect(multi_context.kind).to eq("multi")
        expect(multi_context.valid?).to be_truthy
      end

      it "will return the single kind context if only one is provided" do
        user_context = subject.create({ key: "user-key" })
        multi_context = subject.create_multi([user_context])

        expect(multi_context).to be_a(LaunchDarkly::LDContext)
        expect(multi_context).to eq(user_context)
      end

      it "cannot include another multi-kind context" do
        user_context = subject.create({ key: "user-key" })
        org_context = subject.create({ key: "org-key", kind: "org" })
        embedded_multi_context = subject.create_multi([user_context, org_context])
        multi_context = subject.create_multi([embedded_multi_context])

        expect(multi_context).to be_a(LaunchDarkly::LDContext)
        expect(multi_context.valid?).to be_falsey
      end

      it "are invalid if no contexts are provided" do
        multi_context = subject.create_multi([])
        expect(multi_context.valid?).to be_falsey
      end

      it "are invalid if a single context is invalid" do
        valid_context = subject.create({ kind: "user", key: "user-key" })
        invalid_context = subject.create({ kind: "org" })
        multi_context = subject.create_multi([valid_context, invalid_context])

        expect(valid_context.valid?).to be_truthy
        expect(invalid_context.valid?).to be_falsey
        expect(multi_context.valid?).to be_falsey
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
        user_context = subject.create({ key: 'user', name: 'Ruby', anonymous: true })
        org_context = subject.create({ key: 'ld', kind: 'org', name: 'LaunchDarkly', anonymous: false })

        multi_context = subject.create_multi([user_context, org_context])

        [
          ['kind', eq('multi')],
          ['key', be_nil],
          ['name', be_nil],
          ['anonymous', be_nil],
        ].each do |(reference, matcher)|
          expect(multi_context.get_value_for_reference(LaunchDarkly::Reference.create(reference))).to matcher
        end
      end

      it "with basic attributes" do
        legacy_user = subject.create({ key: 'user', name: 'Ruby', privateAttributeNames: ['name'] })
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
          ref = LaunchDarkly::Reference.create(reference)
          expect(legacy_user.get_value_for_reference(ref)).to user_matcher
          expect(org_context.get_value_for_reference(ref)).to org_matcher
        end
      end

      it "with complex attributes" do
        address = { city: "Oakland", state: "CA", zip: 94612 }
        tags = ["LaunchDarkly", "Feature Flags"]
        nested = { upper: { middle: { name: "Middle Level", inner: { levels: [0, 1, 2] } }, name: "Upper Level" } }

        legacy_user = subject.create({ key: 'user', name: 'Ruby', custom: { address: address, tags: tags, nested: nested }})
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
          ref = LaunchDarkly::Reference.create(reference)
          expect(legacy_user.get_value_for_reference(ref)).to matcher
          expect(org_context.get_value_for_reference(ref)).to matcher
        end
      end
    end
  end
end
