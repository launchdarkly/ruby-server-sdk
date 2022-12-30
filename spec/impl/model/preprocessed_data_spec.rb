require "ldclient-rb/impl/model/feature_flag"
require "model_builders"
require "spec_helper"

module LaunchDarkly
  module Impl
    module DataModelPreprocessing
      describe "preprocessed data is not emitted in JSON" do
        it "for flag" do
          original_flag = {
            key: 'flagkey',
            version: 1,
            on: true,
            offVariation: 0,
            variations: [true, false],
            fallthroughVariation: 1,
            prerequisites: [
              { key: 'a', variation: 0 },
            ],
            targets: [
              { variation: 0, values: ['a'] },
            ],
            rules: [
              {
                variation: 0,
                clauses: [
                  { attribute: 'key', op: 'in', values: ['a'] },
                ],
              },
            ],
          }
          flag = Model::FeatureFlag.new(original_flag)
          json = Model.serialize(FEATURES, flag)
          parsed = JSON.parse(json, symbolize_names: true)
          expect(parsed).to eq(original_flag)
        end
      end
    end
  end
end
