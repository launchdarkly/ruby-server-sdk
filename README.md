LaunchDarkly SDK for Ruby
===========================

Quick setup
-----------

1. Install the Ruby SDK with `gem`

        gem install ldclient-py

2. Create a new LDClient with your API key:

        client = LDClient.new("your_api_key")

Your first feature flag
-----------------------

1. Create a new feature flag on your [dashboard](https://app.launchdarkly.com)
2. In your application code, use the feature's key to check wthether the flag is on for each user:

        if client.get_flag?("your.flag.key", {"key": "user@test.com"}, false)
            # application code to show the feature
        else
            # the code to run if the feature is off
        end