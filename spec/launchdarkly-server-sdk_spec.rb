require "spec_helper"
require "bundler"

describe LaunchDarkly do
  it "can be automatically loaded by Bundler.require" do
    ldclient_loaded =
      Bundler.with_clean_env do
        Kernel.system("ruby", "-e", <<~RUBY)
          require "bundler/setup"
          require "bundler/inline"

          gemfile do
            gem "launchdarkly-server-sdk", path: "."
          end

          Bundler.require(:development)
          abort unless $LOADED_FEATURES.any?(/ldclient-rb\.rb/)
        RUBY
      end

    expect(ldclient_loaded).to be true
  end
end
