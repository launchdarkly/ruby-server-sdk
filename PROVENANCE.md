## Verifying SDK build provenance with the SLSA framework

LaunchDarkly uses the [SLSA framework](https://slsa.dev/spec/v1.0/about) (Supply-chain Levels for Software Artifacts) to help developers make their supply chain more secure by ensuring the authenticity and build integrity of our published SDK packages.

As part of [SLSA requirements for level 3 compliance](https://slsa.dev/spec/v1.0/requirements), LaunchDarkly publishes provenance about our SDK package builds using [GitHub's generic SLSA3 provenance generator](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md#generation-of-slsa3-provenance-for-arbitrary-projects) for distribution alongside our packages. These attestations are available for download from the GitHub release page for the release version under Assets > `multiple-provenance.intoto.jsonl`.

To verify SLSA provenance attestations, we recommend using [slsa-verifier](https://github.com/slsa-framework/slsa-verifier). Example usage for verifying SDK packages is included below:

```
# Download gem
$ gem fetch launchdarkly-server-sdk

# Download provenance from Github release
$ curl --location -O \
  https://github.com/launchdarkly/ruby-server-sdk/releases/download/VERSION/multiple.intoto.jsonl

# Run slsa-verifier to verify provenance against package artifacts 
$ slsa-verifier verify-artifact \
--provenance-path multiple-provenance.intoto.jsonl \
--source-uri github.com/launchdarkly/ruby-server-sdk \
launchdarkly-server-sdk-VERSION.gem
```

Alternatively, to verify the provenance manually, the SLSA framework specifies [recommendations for verifying build artifacts](https://slsa.dev/spec/v1.0/verifying-artifacts) in their documentation.

**Note:** These instructions do not apply when building our SDKs from source. 
