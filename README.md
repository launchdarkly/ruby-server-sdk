LaunchDarkly SDK for Ruby
===========================

[![Gem Version](https://badge.fury.io/rb/ldclient-rb.svg)](http://badge.fury.io/rb/ldclient-rb)

[![Circle CI](https://circleci.com/gh/launchdarkly/ruby-client/tree/master.svg?style=svg)](https://circleci.com/gh/launchdarkly/ruby-client/tree/master)
[![Test Coverage](https://codeclimate.com/github/launchdarkly/ruby-client/badges/coverage.svg)](https://codeclimate.com/github/launchdarkly/ruby-client/coverage)
[![security](https://hakiri.io/github/launchdarkly/ruby-client/master.svg)](https://hakiri.io/github/launchdarkly/ruby-client/master)

Supported Ruby versions
-----------------------

This version of the LaunchDarkly SDK has a minimum Ruby version of 2.2.6, or 9.1.6 for JRuby.

Quick setup
-----------

0. Install the Ruby SDK with `gem`

```shell
gem install ldclient-rb
```

1. Require the LaunchDarkly client:

```ruby
require 'ldclient-rb'
```

2. Create a new LDClient with your SDK key:

```ruby
client = LaunchDarkly::LDClient.new("your_sdk_key")
```

### Ruby on Rails

0.  Add `gem 'ldclient-rb'` to your Gemfile and `bundle install`

1.  Initialize the launchdarkly client in `config/initializers/launchdarkly.rb`:

```ruby
Rails.configuration.ld_client = LaunchDarkly::LDClient.new("your_sdk_key")
```

2.  You may want to include a function in your ApplicationController

```ruby
    def launchdarkly_settings
      if current_user.present?
        {
          key: current_user.id,
          anonymous: false,
          email: current_user.email,
          custom: { groups: current_user.groups.pluck(:name) },
          # Any other fields you may have
          # e.g. lastName: current_user.last_name,
        }
      else
        if Rails::VERSION::MAJOR <= 3
          hash_key = request.session_options[:id]
        else
          hash_key = session.id
        end
        # session ids should be private to prevent session hijacking
        hash_key = Digest::SHA256.base64digest hash_key
        {
          key: hash_key,
          anonymous: true,
        }
      end
    end
```

3.  In your controllers, access the client using

```ruby
Rails.application.config.ld_client.variation('your.flag.key', launchdarkly_settings, false)
```

Note that this gem will automatically switch to using the Rails logger it is detected.


HTTPS proxy
-----------

The Ruby SDK uses Faraday and Socketry to handle its network traffic. Both of these provide built-in support for the use of an  HTTPS proxy. If the HTTPS_PROXY environment variable is present then the SDK will proxy all network requests through the URL provided.

How to set the HTTPS_PROXY environment variable on Mac/Linux systems:
```
export HTTPS_PROXY=https://web-proxy.domain.com:8080
```


How to set the HTTPS_PROXY environment variable on Windows systems:
```
set HTTPS_PROXY=https://web-proxy.domain.com:8080
```


If your proxy requires authentication then you can prefix the URN with your login information:
```
export HTTPS_PROXY=http://user:pass@web-proxy.domain.com:8080
```
or
```
set HTTPS_PROXY=http://user:pass@web-proxy.domain.com:8080
```


Your first feature flag
-----------------------

1. Create a new feature flag on your [dashboard](https://app.launchdarkly.com)
2. In your application code, use the feature's key to check whether the flag is on for each user:

```ruby
if client.variation("your.flag.key", {key: "user@test.com"}, false)
  # application code to show the feature
else
  # the code to run if the feature is off
end
```

Database integrations
---------------------

Feature flag data can be kept in a persistent store using Redis, DynamoDB, or Consul. These adapters are implemented in the `LaunchDarkly::Integrations::Redis`, `LaunchDarkly::Integrations::DynamoDB`, and `LaunchDarkly::Integrations::Consul` modules; to use them, call the `new_feature_store` method in the module, and put the returned object in the `feature_store` property of your client configuration. See the [API documentation](https://www.rubydoc.info/gems/ldclient-rb/LaunchDarkly/Integrations) and the [SDK reference guide](https://docs.launchdarkly.com/v2.0/docs/using-a-persistent-feature-store) for more information.

Using flag data from a file
---------------------------

For testing purposes, the SDK can be made to read feature flag state from a file or files instead of connecting to LaunchDarkly. See [`file_data_source.rb`](https://github.com/launchdarkly/ruby-client/blob/master/lib/ldclient-rb/file_data_source.rb) for more details.

Learn more
-----------

Check out our [documentation](http://docs.launchdarkly.com) for in-depth instructions on configuring and using LaunchDarkly. You can also head straight to the [complete reference guide for this SDK](http://docs.launchdarkly.com/docs/ruby-sdk-reference).

Testing
-------

We run integration tests for all our SDKs using a centralized test harness. This approach gives us the ability to test for consistency across SDKs, as well as test networking behavior in a long-running application. These tests cover each method in the SDK, and verify that event sending, flag evaluation, stream reconnection, and other aspects of the SDK all behave correctly.

Contributing
------------

See [Contributing](https://github.com/launchdarkly/ruby-client/blob/master/CONTRIBUTING.md)

About LaunchDarkly
------------------

* LaunchDarkly is a continuous delivery platform that provides feature flags as a service and allows developers to iterate quickly and safely. We allow you to easily flag your features and manage them from the LaunchDarkly dashboard.  With LaunchDarkly, you can:
    * Roll out a new feature to a subset of your users (like a group of users who opt-in to a beta tester group), gathering feedback and bug reports from real-world use cases.
    * Gradually roll out a feature to an increasing percentage of users, and track the effect that the feature has on key metrics (for instance, how likely is a user to complete a purchase if they have feature A versus feature B?).
    * Turn off a feature that you realize is causing performance problems in production, without needing to re-deploy, or even restart the application with a changed configuration file.
    * Grant access to certain features based on user attributes, like payment plan (eg: users on the ‘gold’ plan get access to more features than users in the ‘silver’ plan). Disable parts of your application to facilitate maintenance, without taking everything offline.
* LaunchDarkly provides feature flag SDKs for
    * [Java](http://docs.launchdarkly.com/docs/java-sdk-reference "Java SDK")
    * [JavaScript](http://docs.launchdarkly.com/docs/js-sdk-reference "LaunchDarkly JavaScript SDK")
    * [PHP](http://docs.launchdarkly.com/docs/php-sdk-reference "LaunchDarkly PHP SDK")
    * [Python](http://docs.launchdarkly.com/docs/python-sdk-reference "LaunchDarkly Python SDK")
    * [Go](http://docs.launchdarkly.com/docs/go-sdk-reference "LaunchDarkly Go SDK")
    * [Node.JS](http://docs.launchdarkly.com/docs/node-sdk-reference "LaunchDarkly Node SDK")
    * [Electron](http://docs.launchdarkly.com/docs/electron-sdk-reference "LaunchDarkly Electron SDK")
    * [.NET](http://docs.launchdarkly.com/docs/dotnet-sdk-reference "LaunchDarkly .Net SDK")
    * [Ruby](http://docs.launchdarkly.com/docs/ruby-sdk-reference "LaunchDarkly Ruby SDK")
    * [iOS](http://docs.launchdarkly.com/docs/ios-sdk-reference "LaunchDarkly iOS SDK")
    * [Android](http://docs.launchdarkly.com/docs/android-sdk-reference "LaunchDarkly Android SDK")
* Explore LaunchDarkly
    * [launchdarkly.com](http://www.launchdarkly.com/ "LaunchDarkly Main Website") for more information
    * [docs.launchdarkly.com](http://docs.launchdarkly.com/  "LaunchDarkly Documentation") for our documentation and SDKs
    * [apidocs.launchdarkly.com](http://apidocs.launchdarkly.com/  "LaunchDarkly API Documentation") for our API documentation
    * [blog.launchdarkly.com](http://blog.launchdarkly.com/  "LaunchDarkly Blog Documentation") for the latest product updates
    * [Feature Flagging Guide](https://github.com/launchdarkly/featureflags/  "Feature Flagging Guide") for best practices and strategies
