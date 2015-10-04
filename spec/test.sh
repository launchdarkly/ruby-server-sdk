#!/usr/bin/env bash
# Copied from http://ylan.segal-family.com/blog/2013/06/21/testing-with-multiple-ruby-and-gem-versions/

set -e

rubies=("ruby-2.2.3" "ruby-2.1.7" "ruby-2.0.0" "ruby-1.9.3" "jruby-1.7.22" "jruby-1.6.7.2")
for i in "${rubies[@]}"
do
  echo "====================================================="
  echo "$i: Start Test"
  echo "====================================================="
  rvm install $i
  rvm use $i
  gem install bundler
  bundle install
  bundle exec rspec spec
  echo "====================================================="
  echo "$i: End Test"
  echo "====================================================="
done
