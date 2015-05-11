LaunchDarkly SDK for Ruby
===========================

Quick setup
-----------

0. Install the Ruby SDK with `gem`

        gem install ldclient-rb

1. Require the LaunchDarkly client:

        require 'ldclient-rb'


2. Create a new LDClient with your API key:

        client = LaunchDarkly::LDClient.new("your_api_key")

Your first feature flag
-----------------------

1. Create a new feature flag on your [dashboard](https://app.launchdarkly.com)
2. In your application code, use the feature's key to check wthether the flag is on for each user:

        if client.toggle?("your.flag.key", {:key => "user@test.com"}, false)
            # application code to show the feature
        else
            # the code to run if the feature is off
        end

Learn more
-----------

Check out our [documentation](http://docs.launchdarkly.com) for in-depth instructions on configuring and using LaunchDarkly. You can also head straight to the [complete reference guide for this SDK](http://docs.launchdarkly.com/v1.0/docs/ruby-sdk-reference).

Contributing
------------

We encourage pull-requests and other contributions from the community. We've also published an [SDK contributor's guide](http://docs.launchdarkly.com/v1.0/docs/sdk-contributors-guide) that provides a detailed explanation of how our SDKs work.
