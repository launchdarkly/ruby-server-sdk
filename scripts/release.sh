#!/usr/bin/env bash
# This script updates the version for the ldclient library and releases it to RubyGems
# It will only work if you have the proper credentials set up in ~/.gem/credentials

# It takes exactly one argument: the new version.
# It should be run from the root of this git repo like this:
#   ./scripts/release.sh 4.0.9

# When done you should commit and push the changes made.

set -uxe
echo "Starting ruby-server-sdk release."

VERSION=$1

#Update version in ldclient/version.py
VERSION_RB_TEMP=./version.rb.tmp
sed "s/VERSION =.*/VERSION = \"${VERSION}\"/g" lib/ldclient-rb/version.rb > ${VERSION_RB_TEMP}
mv ${VERSION_RB_TEMP} lib/ldclient-rb/version.rb

# Build Ruby Gem
gem build ldclient-rb.gemspec

# Publish Ruby Gem
gem push ldclient-rb-${VERSION}.gem

echo "Done with ruby-server-sdk release"