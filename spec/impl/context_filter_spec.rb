require "spec_helper"

module LaunchDarkly
  module Impl
    describe ContextFilter do
      it "reports redacted attribute names as escaped attribute references" do
        filter = ContextFilter.new(true, [])
        context = LDContext.create({ kind: "user", key: "user-key", :"/ssn" => "123-45-6789", :"a/b~c" => "value" })

        filtered = filter.filter(context)

        expect(filtered[:_meta][:redactedAttributes]).to contain_exactly(:"/~1ssn", :"a/b~c")
      end

      it "escapes redacted attribute names when redacting anonymous contexts" do
        filter = ContextFilter.new(false, [])
        context = LDContext.create({ kind: "user", key: "user-key", anonymous: true, name: "name", :"/ssn" => "123-45-6789" })

        filtered = filter.filter_redact_anonymous(context)

        expect(filtered[:_meta][:redactedAttributes]).to contain_exactly(:name, :"/~1ssn")
      end

      it "escapes redacted attribute names configured as private" do
        filter = ContextFilter.new(false, ["/~1ssn"])
        context = LDContext.create({ kind: "user", key: "user-key", :"/ssn" => "123-45-6789", name: "name" })

        filtered = filter.filter(context)

        expect(filtered[:name]).to eq("name")
        expect(filtered[:_meta][:redactedAttributes]).to eq([:"/~1ssn"])
      end

      it "does not apply per-context private attributes to later contexts" do
        filter = ContextFilter.new(false, [])
        private_context = LDContext.create({ kind: "user", key: "user-key", email: "email", _meta: { privateAttributes: ["email"] } })
        other_context = LDContext.create({ kind: "user", key: "other-key", email: "email" })

        expect(filter.filter(private_context)[:_meta][:redactedAttributes]).to eq([:email])
        expect(filter.filter(other_context)).to eq({ key: "other-key", kind: "user", email: "email" })
      end

      it "does not apply private attributes of one kind to the other kinds of a multi-kind context" do
        filter = ContextFilter.new(false, [])
        context = LDContext.create_multi([
                                           LDContext.create({ kind: "user", key: "user-key", email: "email", _meta: { privateAttributes: ["email"] } }),
          LDContext.create({ kind: "org", key: "org-key", email: "email" }),
                                         ])

        filtered = filter.filter(context)

        expect(filtered["user"][:_meta][:redactedAttributes]).to eq([:email])
        expect(filtered["org"]).to eq({ key: "org-key", email: "email" })
      end

      describe "with string keyed attribute data" do
        it "redacts a nested private attribute" do
          filter = ContextFilter.new(false, ["/profile/email"])
          context = LDContext.create({ kind: "user", key: "user-key", profile: JSON.parse('{"email":"private@example.test","plan":"pro"}') })

          filtered = filter.filter(context)

          expect(filtered[:profile]).to eq({ "plan" => "pro" })
          expect(filtered[:_meta][:redactedAttributes]).to eq([:"/profile/email"])
        end

        it "redacts a nested per-context private attribute" do
          filter = ContextFilter.new(false, [])
          context = LDContext.create({
            kind: "user",
            key: "user-key",
            account: JSON.parse('{"apiToken":"private-token","region":"test-region"}'),
            _meta: { privateAttributes: ["/account/apiToken"] },
          })

          filtered = filter.filter(context)

          expect(filtered[:account]).to eq({ "region" => "test-region" })
          expect(filtered[:_meta][:redactedAttributes]).to eq([:"/account/apiToken"])
        end

        it "produces the same event payload as symbol keyed data" do
          filter = ContextFilter.new(false, ["/profile/email"])
          json = '{"email":"private@example.test","plan":"pro"}'
          string_keyed = LDContext.create({ kind: "user", key: "user-key", profile: JSON.parse(json) })
          symbol_keyed = LDContext.create({ kind: "user", key: "user-key", profile: JSON.parse(json, symbolize_names: true) })

          # The two hashes keep the key type they were given, so compare the
          # payloads the way the event sender sees them. A string key and a
          # symbol key serialize to the same JSON property name.
          expect(JSON.generate(filter.filter(string_keyed))).to eq(JSON.generate(filter.filter(symbol_keyed)))
        end

        it "redacts a private attribute nested three levels deep" do
          filter = ContextFilter.new(false, ["/a/b/c"])
          context = LDContext.create({ kind: "user", key: "user-key", a: JSON.parse('{"b":{"c":"private","d":"keep"}}') })

          filtered = filter.filter(context)

          expect(filtered[:a]).to eq({ "b" => { "d" => "keep" } })
          expect(filtered[:_meta][:redactedAttributes]).to eq([:"/a/b/c"])
        end

        it "redacts both the string and the symbol form of one name, and reports the reference once" do
          filter = ContextFilter.new(false, ["/profile/email"])
          context = LDContext.create({
            kind: "user",
            key: "user-key",
            profile: { :email => "symbol-private", "email" => "string-private", "other" => "keep" },
          })

          filtered = filter.filter(context)

          expect(filtered[:profile]).to eq({ "other" => "keep" })
          expect(filtered[:_meta][:redactedAttributes]).to eq([:"/profile/email"])
        end

        it "redacts a nested private attribute under a string top level key" do
          filter = ContextFilter.new(false, ["/profile/email"])
          context = LDContext.create({ :kind => "user", :key => "user-key", "profile" => JSON.parse('{"email":"private@example.test","plan":"pro"}') })

          filtered = filter.filter(context)

          expect(filtered["profile"]).to eq({ "plan" => "pro" })
          expect(filtered[:_meta][:redactedAttributes]).to eq([:"/profile/email"])
        end

        it "redacts an escaped nested private attribute name" do
          filter = ContextFilter.new(false, ["/profile/a~1b"])
          context = LDContext.create({ kind: "user", key: "user-key", profile: JSON.parse('{"a/b":"private","keep":"keep"}') })

          filtered = filter.filter(context)

          expect(filtered[:profile]).to eq({ "keep" => "keep" })
          expect(filtered[:_meta][:redactedAttributes]).to eq([:"/profile/a~1b"])
        end
      end
    end
  end
end
