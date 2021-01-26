require "spec_helper"
require "bundler"

describe LaunchDarkly do
  it "can be automatically loaded by Bundler.require" do
    ldclient_loaded =
      Bundler.with_unbundled_env do
        Kernel.system("ruby", "./spec/launchdarkly-server-sdk_spec_autoloadtest.rb")
      end

    expect(ldclient_loaded).to be true
  end
end
