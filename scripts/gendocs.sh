#!/bin/bash

gem install --conservative yard
gem install --conservative redcarpet  # provides Markdown formatting

# yard doesn't seem to do recursive directories, even though Ruby's Dir.glob supposedly recurses for "**"
PATHS="lib/*.rb lib/**/*.rb lib/**/**/*.rb lib/**/**/**/*.rb"

yard doc --no-private --markup markdown --markup-provider redcarpet --embed-mixins $PATHS - README.md
