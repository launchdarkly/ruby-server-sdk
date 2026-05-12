# frozen_string_literal: true

require "spec_helper"
require "ldclient-rb/impl/data_store/feature_store_client_wrapper"

module LaunchDarkly
  module Impl
    module DataStore
      describe FeatureStoreClientWrapperV2 do
        let(:logger) { double.as_null_object }
        let(:status_sink) { double(update_status: nil) }

        describe "#disable_cache" do
          it "forwards to the underlying store when supported" do
            inner = double("store", disable_cache: nil, init: nil, get: nil, all: nil, delete: nil, upsert: nil, initialized?: false, stop: nil)
            expect(inner).to receive(:disable_cache).once

            wrapper = described_class.new(inner, status_sink, logger)
            wrapper.disable_cache
          end

          it "is a no-op when the underlying store does not respond to disable_cache" do
            inner = Class.new do
              def init(_); end
              def get(_, _); end
              def all(_); end
              def delete(_, _, _); end
              def upsert(_, _); end
              def initialized?; false; end
              def stop; end
            end.new

            wrapper = described_class.new(inner, status_sink, logger)
            expect { wrapper.disable_cache }.not_to raise_error
          end
        end
      end
    end
  end
end
