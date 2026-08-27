require "spec_helper"
require "capturing_logger"

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

      it "omits top-level attributes with non-symbol names" do
        filter = ContextFilter.new(false, [])
        context = LDContext.create({ kind: "user", key: "user-key", "legacy" => "value", plan: "basic" })

        filtered = filter.filter(context)

        expect(filtered).to eq({ key: "user-key", kind: "user", plan: "basic" })
      end

      it "omits nested attributes with non-symbol names at any depth" do
        filter = ContextFilter.new(false, [])
        context = LDContext.create({ kind: "user", key: "user-key",
                                     address: { street: "123 Easy St", "city" => "Springfield",
                                                extra: { "deep" => 1, depth: 2 } } })

        filtered = filter.filter(context)

        expect(filtered[:address]).to eq({ street: "123 Easy St", extra: { depth: 2 } })
      end

      it "omits the whole subtree under a non-symbol name" do
        filter = ContextFilter.new(false, [])
        context = LDContext.create({ kind: "user", key: "user-key",
                                     profile: { "nested" => { a: 1 }, ok: true } })

        filtered = filter.filter(context)

        expect(filtered[:profile]).to eq({ ok: true })
      end

      it "does not report attributes with non-symbol names as redacted" do
        filter = ContextFilter.new(true, [])
        context = LDContext.create({ kind: "user", key: "user-key", "legacy" => "value", plan: "basic" })

        filtered = filter.filter(context)

        expect(filtered[:_meta][:redactedAttributes]).to eq([:plan])
      end

      it "redacts private attributes while omitting attributes with non-symbol names" do
        filter = ContextFilter.new(false, ["/address/zip"])
        context = LDContext.create({ kind: "user", key: "user-key",
                                     address: { street: "123 Easy St", "city" => "Springfield", zip: "97475" } })

        filtered = filter.filter(context)

        expect(filtered[:address]).to eq({ street: "123 Easy St" })
        expect(filtered[:_meta][:redactedAttributes]).to eq([:"/address/zip"])
      end

      it "logs an error only once when attributes with non-symbol names are omitted" do
        logger = CapturingLogger.new
        filter = ContextFilter.new(false, [], logger)
        context = LDContext.create({ kind: "user", key: "user-key", "legacy" => "value",
                                     address: { "city" => "Springfield" } })

        filter.filter(context)
        filter.filter(context)

        expect(logger.output.scan(/non-symbol names/).length).to eq(1)
        expect(logger.output).to include("ERROR")
      end

      it "does not log when all attribute names are symbols" do
        logger = CapturingLogger.new
        filter = ContextFilter.new(false, [], logger)
        context = LDContext.create({ kind: "user", key: "user-key", plan: "basic" })

        filter.filter(context)

        expect(logger.output).to eq("")
      end

      it "omits a nested value that refers to its own ancestor" do
        address = { street: "123 Easy St" }
        address[:self] = address
        filter = ContextFilter.new(false, [])
        context = LDContext.create({ kind: "user", key: "user-key", address: address })

        filtered = filter.filter(context)

        expect(filtered[:address]).to eq({ street: "123 Easy St", self: { street: "123 Easy St" } })
      end

      it "matches private references against the paths present in the output for cyclic values" do
        address = { street: "123 Easy St", city: "Springfield" }
        address[:self] = address
        filter = ContextFilter.new(false, ["/address/street"])
        context = LDContext.create({ kind: "user", key: "user-key", address: address })

        filtered = filter.filter(context)

        expect(filtered[:address]).to eq({ city: "Springfield", self: { street: "123 Easy St", city: "Springfield" } })
        expect(filtered[:_meta][:redactedAttributes]).to eq([:"/address/street"])
      end

      it "keeps a value that appears in more than one branch" do
        shared = { city: "Springfield" }
        filter = ContextFilter.new(false, [])
        context = LDContext.create({ kind: "user", key: "user-key",
                                     addresses: { home: shared, work: shared } })

        filtered = filter.filter(context)

        expect(filtered[:addresses]).to eq({ home: { city: "Springfield" }, work: { city: "Springfield" } })
      end
    end
  end
end
