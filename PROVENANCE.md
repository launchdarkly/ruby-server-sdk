## Verifying SDK build provenance with the SLSA framework

LaunchDarkly uses the [SLSA framework](https://slsa.dev/spec/v1.0/about) (Supply-chain Levels for Software Artifacts) to help developers make their supply chain more secure by ensuring the authenticity and build integrity of our published SDK packages.

As part of [SLSA requirements for level 3 compliance](https://slsa.dev/spec/v1.0/requirements), LaunchDarkly publishes provenance about our SDK package builds using [GitHub's generic SLSA3 provenance generator](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md#generation-of-slsa3-provenance-for-arbitrary-projects) for distribution alongside our packages. These attestations are available for download from the GitHub release page for the release version under Assets > `multiple-provenance.intoto.jsonl`.

To verify SLSA provenance attestations, we recommend using [slsa-verifier](https://github.com/slsa-framework/slsa-verifier). Example usage for verifying SDK packages is included below:

<!-- x-release-please-start-version -->
```
# Set the version of the SDK to verify
SDK_VERSION=8.9.0
```
<!-- x-release-please-end -->

```
# Download gem
$ gem fetch launchdarkly-server-sdk -v $SDK_VERSION

# Download provenance from Github release
$ curl --location -O \
  https://github.com/launchdarkly/ruby-server-sdk/releases/download/${SDK_VERSION}/launchdarkly-server-sdk-${SDK_VERSION}.gem.intoto.jsonl

# Run slsa-verifier to verify provenance against package artifacts 
$ slsa-verifier verify-artifact \
--provenance-path launchdarkly-server-sdk-${SDK_VERSION}.gem.intoto.jsonl \
--source-uri github.com/launchdarkly/ruby-server-sdk \
launchdarkly-server-sdk-${SDK_VERSION}.gem
```

Below is a sample of expected output.

```
Verified signature against tlog entry index 78214752 at URL: https://rekor.sigstore.dev/api/v1/log/entries/24296fb24b8ad77ab941c118ef7e0b2d656b962a0d670c6ac91cfa37d07b7b121ae560b00a978ecf
Verified build using builder "https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@refs/tags/v1.7.0" at commit f43b3ad834103fdc282652efbfe4963e8dfa737b
Verifying artifact launchdarkly-server-sdk-8.3.0.gem: PASSED

PASSED: Verified SLSA provenance
```

Alternatively, to verify the provenance manually, the SLSA framework specifies [recommendations for verifying build artifacts](https://slsa.dev/spec/v1.0/verifying-artifacts) in their documentation.

**Note:** These instructions do not apply when building our SDKs from source. 
