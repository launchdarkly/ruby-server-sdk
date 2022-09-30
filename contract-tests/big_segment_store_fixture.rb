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

  def get_membership(user_hash)
    response = HTTP.post("#{@uri}/getMembership", :json => {:userHash => user_hash})
    json = response.parse(:json)

    return json['values']
  end

  def stop
    HTTP.delete("#{@uri}")
  end
end
