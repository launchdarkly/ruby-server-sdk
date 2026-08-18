require "spec_helper"

module LaunchDarkly
  module Impl
    describe ContextFilter do
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
    end
  end
end
