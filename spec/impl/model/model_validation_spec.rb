require "ldclient-rb/impl/model/feature_flag"

require "capturing_logger"
require "model_builders"
require "spec_helper"


def base_flag
  FlagBuilder.new("flagkey").build.as_json
end

def base_segment
  FlagBuilder.new("flagkey").build.as_json
end

def rules_with_clause(clause)
  {
    rules: [
      { variation: 0, clauses: [ clause ] },
    ],
  }
end

def segment_rules_with_clause(clause)
  {
    rules: [
      { clauses: [ clause ] },
    ],
  }
end


module LaunchDarkly
  module Impl
    describe "flag model validation" do
      describe "should not log errors for" do
        [
          [
            "minimal valid flag",
            base_flag,
          ],
          [
            "valid off variation",
            base_flag.merge({variations: [true, false], offVariation: 1}),
          ],
          [
            "valid fallthrough variation",
            base_flag.merge({variations: [true, false], fallthrough: {variation: 1}}),
          ],
          [
            "valid fallthrough rollout",
            base_flag.merge({variations: [true, false], fallthrough: {
              rollout: {
                variations: [
                  { variation: 0, weight: 100000 },
                ],
              },
            }}),
          ],
          [
            "valid target variation",
            base_flag.merge({variations: [true, false], targets: [ {variation: 1, values: []} ]}),
          ],
          [
            "valid rule variation",
            base_flag.merge({variations: [true, false], rules: [ {variation: 1, clauses: []} ]}),
          ],
          [
            "valid attribute reference",
            base_flag.merge(rules_with_clause({
              attribute: "name", op: "in", values: ["a"]
            })),
          ],
          [
            "missing attribute reference when operator is segmentMatch",
            base_flag.merge(rules_with_clause({
              op: "segmentMatch", values: ["a"]
            })),
          ],
          [
            "empty attribute reference when operator is segmentMatch",
            base_flag.merge(rules_with_clause({
              attribute: "", op: "segmentMatch", values: ["a"]
            })),
          ],
        ].each do |params|
          (name, flag_data_hash) = params
          it(name) do
            logger = CapturingLogger.new
            LaunchDarkly::Impl::Model::FeatureFlag.new(flag_data_hash, logger)
            expect(logger.output).to eq('')
          end
        end
      end

      describe "should log errors for" do
        [
          [
            "negative off variation",
            base_flag.merge({variations: [true, false], offVariation: -1}),
            "off variation has invalid variation index",
          ],
          [
            "too high off variation",
            base_flag.merge({variations: [true, false], offVariation: 2}),
            "off variation has invalid variation index",
          ],
          [
            "negative fallthrough variation",
            base_flag.merge({variations: [true, false], fallthrough: {variation: -1}}),
            "fallthrough has invalid variation index",
          ],
          [
            "too high fallthrough variation",
            base_flag.merge({variations: [true, false], fallthrough: {variation: 2}}),
            "fallthrough has invalid variation index",
          ],
          [
            "negative fallthrough rollout variation",
            base_flag.merge({variations: [true, false], fallthrough: {
              rollout: {
                variations: [
                  { variation: -1, weight: 100000 },
                ],
              },
            }}),
            "fallthrough has invalid variation index",
          ],
          [
            "fallthrough rollout too high variation",
            base_flag.merge({variations: [true, false], fallthrough: {
              rollout: {
                variations: [
                  { variation: 2, weight: 100000 },
                ],
              },
            }}),
            "fallthrough has invalid variation index",
          ],
          [
            "negative target variation",
            base_flag.merge({
              variations: [true, false],
              targets: [
                { variation: -1, values: [] },
              ],
            }),
            "target has invalid variation index",
          ],
          [
            "too high rule variation",
            base_flag.merge({
              variations: [true, false],
              targets: [
                { variation: 2, values: [] },
              ],
            }),
            "target has invalid variation index",
          ],
          [
            "negative rule variation",
            base_flag.merge({
              variations: [true, false],
              rules: [
                { variation: -1, clauses: [] },
              ],
            }),
            "rule has invalid variation index",
          ],
          [
            "too high rule variation",
            base_flag.merge({
              variations: [true, false],
              rules: [
                { variation: 2, clauses: [] },
              ],
            }),
            "rule has invalid variation index",
          ],
          [
            "negative rule rollout variation",
            base_flag.merge({
              variations: [true, false],
              rules: [
                { rollout: { variations: [ { variation: -1, weight: 10000 } ] }, clauses: [] },
              ],
            }),
            "rule has invalid variation index",
          ],
          [
            "too high rule variation",
            base_flag.merge({
              variations: [true, false],
              rules: [
                { rollout: { variations: [ { variation: 2, weight: 10000 } ] }, clauses: [] },
              ],
            }),
            "rule has invalid variation index",
          ],
          [
            "missing attribute reference",
            base_flag.merge(rules_with_clause({ op: "in", values: ["a"] })),
            "clause has invalid attribute: empty reference",
          ],
          [
            "empty attribute reference",
            base_flag.merge(rules_with_clause({ attribute: "", op: "in", values: ["a"] })),
            "clause has invalid attribute: empty reference",
          ],
          [
            "invalid attribute reference",
            base_flag.merge(rules_with_clause({ contextKind: "user", attribute: "//", op: "in", values: ["a"] })),
            "clause has invalid attribute: double or trailing slash",
          ],
        ].each do |params|
          (name, flag_data_hash, expected_error) = params
          it(name) do
            logger = CapturingLogger.new
            LaunchDarkly::Impl::Model::FeatureFlag.new(flag_data_hash, logger)
            expect(logger.output).to match(Regexp.escape(
              "Data inconsistency in feature flag \"#{flag_data_hash[:key]}\": #{expected_error}"
            ))
          end
        end
      end
    end

    describe "segment model validation" do
      describe "should not log errors for" do
        [
          [
            "minimal valid segment",
            base_segment,
          ],
        ].each do |params|
          (name, segment_data_hash) = params
          it(name) do
            logger = CapturingLogger.new
            LaunchDarkly::Impl::Model::Segment.new(segment_data_hash, logger)
            expect(logger.output).to eq('')
          end
        end
      end
    end

    describe "should log errors for" do
      [
        [
          "missing attribute reference",
          base_segment.merge(segment_rules_with_clause({ op: "in", values: ["a"] })),
          "clause has invalid attribute: empty reference",
        ],
        [
          "empty attribute reference",
          base_segment.merge(segment_rules_with_clause({ attribute: "", op: "in", values: ["a"] })),
          "clause has invalid attribute: empty reference",
        ],
        [
          "invalid attribute reference",
          base_segment.merge(segment_rules_with_clause({ contextKind: "user", attribute: "//", op: "in", values: ["a"] })),
          "clause has invalid attribute: double or trailing slash",
        ],
      ].each do |params|
        (name, segment_data_hash, expected_error) = params
        it(name) do
          logger = CapturingLogger.new
          LaunchDarkly::Impl::Model::Segment.new(segment_data_hash, logger)
          expect(logger.output).to match(Regexp.escape(
            "Data inconsistency in segment \"#{segment_data_hash[:key]}\": #{expected_error}"
          ))
        end
      end
    end
  end
end
