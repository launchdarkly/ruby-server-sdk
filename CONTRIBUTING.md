Contributing to the LaunchDarkly Server-side SDK for Ruby
================================================

LaunchDarkly has published an [SDK contributor's guide](https://docs.launchdarkly.com/docs/sdk-contributors-guide) that provides a detailed explanation of how our SDKs work. See below for additional information on how to contribute to this SDK.

Submitting bug reports and feature requests
------------------

The LaunchDarkly SDK team monitors the [issue tracker](https://github.com/launchdarkly/ruby-server-sdk/issues) in the SDK repository. Bug reports and feature requests specific to this SDK should be filed in this issue tracker. The SDK team will respond to all newly filed issues within two business days.

Submitting pull requests
------------------

We encourage pull requests and other contributions from the community. Before submitting pull requests, ensure that all temporary or unintended code is removed. Don't worry about adding reviewers to the pull request; the LaunchDarkly SDK team will add themselves. The SDK team will acknowledge all pull requests within two business days.

Build instructions
------------------

### Prerequisites

This SDK is built with [Bundler](https://bundler.io/). To install Bundler, run `gem install bundler -v 1.17.3`. You might need `sudo` to execute the command successfully. As of this writing, the SDK does not support being built with Bundler 2.0.

### Building

To build the SDK without running any tests:

```
bundle install
```

### Testing

To run all unit tests:

```
bundle exec rspec spec
```