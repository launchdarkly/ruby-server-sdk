# coding: utf-8

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "ldclient-rb/version"

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
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 2.4.0"

  spec.add_development_dependency "aws-sdk-dynamodb", "~> 1.18"
  spec.add_development_dependency "bundler", "~> 1.17"
  spec.add_development_dependency "rspec", "~> 3.2"
  spec.add_development_dependency "diplomat", ">= 2.0.2"
  spec.add_development_dependency "redis", "~> 3.3.5"
  spec.add_development_dependency "connection_pool", ">= 2.1.2"
  spec.add_development_dependency "rspec_junit_formatter", "~> 0.3.0"
  spec.add_development_dependency "timecop", "~> 0.9.1"
  spec.add_development_dependency "listen", "~> 3.0" # see file_data_source.rb
  # these are transitive dependencies of listen and consul respectively
  # we constrain them here to make sure the ruby 2.2, 2.3, and 2.4 CI
  # cases all pass
  spec.add_development_dependency "ffi", "<= 1.12" # >1.12 doesnt support ruby 2.2
  spec.add_development_dependency "faraday", "~> 0.17" # >=0.18 doesnt support ruby 2.2

  spec.add_runtime_dependency "semantic", "~> 1.6"
  spec.add_runtime_dependency "concurrent-ruby", "~> 1.0"
  spec.add_runtime_dependency "ld-eventsource", "1.0.3"

  # lock json to 2.3.x as ruby libraries often remove
  # support for older ruby versions in minor releases
  spec.add_runtime_dependency "json", "~> 2.3.1"
end
