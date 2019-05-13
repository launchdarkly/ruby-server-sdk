#!/bin/bash

# Use this script to generate documentation locally in ./doc so it can be proofed before release.
# After release, documentation will be visible at https://www.rubydoc.info/gems/launchdarkly-server-sdk

gem install --conservative yard
gem install --conservative redcarpet  # provides Markdown formatting

rm -rf doc/*

yard doc
