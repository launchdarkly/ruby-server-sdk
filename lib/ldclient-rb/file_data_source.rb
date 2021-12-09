require "ldclient-rb/integrations/file_data"

module LaunchDarkly
  #
  # Deprecated entry point for the file data source feature.
  #
  # The new preferred usage is {LaunchDarkly::Integrations::FileData#data_source}.
  #
  # @deprecated This is replaced by {LaunchDarkly::Integrations::FileData}.
  #
  class FileDataSource
    #
    # Deprecated entry point for the file data source feature.
    #
    # The new preferred usage is {LaunchDarkly::Integrations::FileData#data_source}.
    #
    # @deprecated This is replaced by {LaunchDarkly::Integrations::FileData#data_source}.
    #
    def self.factory(options={})
      LaunchDarkly::Integrations::FileData.data_source(options)
    end
  end
end
