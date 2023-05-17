require 'http'

class BigSegmentStoreFixture
  def initialize(uri)
    @uri = uri
  end

  def get_metadata
    response = HTTP.post("#{@uri}/getMetadata")
    json = response.parse(:json)
    LaunchDarkly::Interfaces::BigSegmentStoreMetadata.new(json['lastUpToDate'])
  end

  def get_membership(context_hash)
    response = HTTP.post("#{@uri}/getMembership", :json => {:contextHash => context_hash})
    json = response.parse(:json)

    json['values']
  end

  def stop
    HTTP.delete(@uri)
  end
end
