# coding: utf-8

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "ldclient-rb/version"
#require "rake"

# rubocop:disable Metrics/BlockLength
Gem::Specification.new do |spec|
  spec.name          = "launchdarkly-server-sdk"
  spec.version       = LaunchDarkly::VERSION
  spec.authors       = ["LaunchDarkly"]
  spec.email         = ["team@launchdarkly.com"]
  spec.summary       = "LaunchDarkly SDK for Ruby"
  spec.description   = "Official LaunchDarkly SDK for Ruby"
  spec.homepage      = "https://github.com/launchdarkly/ruby-server-sdk"
  spec.license       = "Apache-2.0"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 2.7.0"

  spec.add_development_dependency "aws-sdk-dynamodb", "~> 1.57"
  spec.add_development_dependency "bundler", "2.2.33"
  spec.add_development_dependency "simplecov", "~> 0.21"
  spec.add_development_dependency "rspec", "~> 3.10"
  spec.add_development_dependency "diplomat", "~> 2.6"
  spec.add_development_dependency "redis", "~> 5.0"
  spec.add_development_dependency "connection_pool", "~> 2.3"
  spec.add_development_dependency "rspec_junit_formatter", "~> 0.4"
  spec.add_development_dependency "timecop", "~> 0.9"
  spec.add_development_dependency "listen", "~> 3.3" # see file_data_source.rb
  spec.add_development_dependency "webrick", "~> 1.7"
  spec.add_development_dependency "rubocop", "~> 1.37"
  spec.add_development_dependency "rubocop-performance", "~> 1.15"

  spec.add_runtime_dependency "semantic", "~> 1.6"
  spec.add_runtime_dependency "concurrent-ruby", "~> 1.1"
  spec.add_runtime_dependency "ld-eventsource", "2.2.2"
  # Please keep ld-eventsource dependency as an exact version so that bugfixes to
  # that LD library are always associated with a new SDK version.

  spec.add_runtime_dependency "json", ">= 2.3"
  spec.add_runtime_dependency "http", ">= 4.4.0", "< 6.0.0"
end
