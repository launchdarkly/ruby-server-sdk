require "model_builders"
require "spec_helper"

def strip_preprocessed_nulls(json)
  # currently we can't avoid emitting these null properties - we just don't want to see anything other than null there
  json.gsub('"_preprocessed":null,', '').gsub(',"_preprocessed":null', '')
end

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
          flag = clone_json_object(original_flag)
          Preprocessor.new().preprocess_flag!(flag)
          json = Model.serialize(FEATURES, flag)
          parsed = JSON.parse(strip_preprocessed_nulls(json), symbolize_names: true)
          expect(parsed).to eq(original_flag)
        end
      end
    end
  end
end
