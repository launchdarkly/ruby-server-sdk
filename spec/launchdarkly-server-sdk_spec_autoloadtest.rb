require "bundler/setup"
require "bundler/inline"

gemfile do
  gem "launchdarkly-server-sdk", path: "."
end

Bundler.require(:development)
abort unless $LOADED_FEATURES.any? { |file| file =~ /ldclient-rb\.rb/ }
