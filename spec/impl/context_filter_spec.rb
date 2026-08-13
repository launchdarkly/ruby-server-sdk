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
    end
  end
end
