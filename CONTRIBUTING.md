# Contributing to the LaunchDarkly Server-side SDK for Ruby

LaunchDarkly has published an [SDK contributor's guide](https://docs.launchdarkly.com/sdk/concepts/contributors-guide) that provides a detailed explanation of how our SDKs work. See below for additional information on how to contribute to this SDK.

## Submitting bug reports and feature requests

The LaunchDarkly SDK team monitors the [issue tracker](https://github.com/launchdarkly/ruby-server-sdk/issues) in the SDK repository. Bug reports and feature requests specific to this SDK should be filed in this issue tracker. The SDK team will respond to all newly filed issues within two business days.

## Submitting pull requests

We encourage pull requests and other contributions from the community. Before submitting pull requests, ensure that all temporary or unintended code is removed. Don't worry about adding reviewers to the pull request; the LaunchDarkly SDK team will add themselves. The SDK team will acknowledge all pull requests within two business days.

## Build instructions

### Prerequisites

This SDK is built with [Bundler](https://bundler.io/). To install Bundler, run `gem install bundler`. You might need `sudo` to execute the command successfully.

To install the runtime dependencies:

```
bundle install
```

### Testing

To run all unit tests:

```
bundle exec rspec spec
```

The full unit test suite includes live tests of the integrations for Consul, DynamoDB, and Redis. Those tests expect you to have instances of all of those databases running locally. By default, these tests will be skipped. To run them, set the environment variable `LD_SKIP_DATABASE_TESTS=0` before running the tests.

### Building documentation

Documentation is built automatically with YARD for each release. To build the documentation locally:

```
cd docs
make
```

The output will appear in `docs/build/html`.

## Code organization

The SDK's namespacing convention is as follows:

* `LaunchDarkly`: This namespace contains the most commonly used classes and methods in the SDK, such as `LDClient` and `EvaluationDetail`.
* `LaunchDarkly::Integrations`: This namespace contains entry points for optional features that are related to how the SDK communicates with other systems, such as `Redis`.
* `LaunchDarkly::Interfaces`: This namespace contains types that do not do anything by themselves, but may need to be referenced if you are using optional features or implementing a custom component.

A special case is the namespace `LaunchDarkly::Impl`, and any namespaces within it. Everything under `Impl` is considered a private implementation detail: all files there are excluded from the generated documentation, and are considered subject to change at any time and not supported for direct use by application developers. We do this because Ruby's scope/visibility system is somewhat limited compared to other languages: a method can be `private` or `protected` within a class, but there is no way to make it visible to other classes in the SDK yet invisible to code outside of the SDK, and there is similarly no way to hide a class.

So, if there is a class whose existence is entirely an implementation detail, it should be in `Impl`. Similarly, classes that are _not_ in `Impl` must not expose any public members that are not meant to be part of the supported public API. This is important because of our guarantee of backward compatibility for all public APIs within a major version: we want to be able to change our implementation details to suit the needs of the code, without worrying about breaking a customer's code. Due to how the language works, we can't actually prevent an application developer from referencing those classes in their code, but this convention makes it clear that such use is discouraged and unsupported.

## Documenting types and methods

All classes and public methods outside of `LaunchDarkly::Impl` should have documentation comments. These are used to build the API documentation that is published at https://launchdarkly.github.io/ruby-server-sdk/ and https://www.rubydoc.info/gems/launchdarkly-server-sdk. The documentation generator is YARD; see https://yardoc.org/ for the comment format it uses.

Please try to make the style and terminology in documentation comments consistent with other documentation comments in the SDK. Also, if a class or method is being added that has an equivalent in other SDKs, and if we have described it in a consistent away in those other SDKs, please reuse the text whenever possible (with adjustments for anything language-specific) rather than writing new text.
