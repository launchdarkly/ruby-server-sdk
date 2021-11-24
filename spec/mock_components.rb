require "ldclient-rb/impl/big_segments"
require "ldclient-rb/interfaces"

module LaunchDarkly
  class MockBigSegmentStore
    def initialize
      @metadata = nil
      @metadata_error = nil
      @memberships = {}
    end

    def get_metadata
      raise @metadata_error if !@metadata_error.nil?
      @metadata
    end

    def get_membership(user_hash)
      @memberships[user_hash]
    end

    def stop
    end

    def setup_metadata(last_up_to_date)
      @metadata = Interfaces::BigSegmentStoreMetadata.new(last_up_to_date.to_f * 1000)
    end

    def setup_metadata_error(ex)
      @metadata_error = ex
    end

    def setup_membership(user_key, membership)
      user_hash = Impl::BigSegmentStoreManager.hash_for_user_key(user_key)
      @memberships[user_hash] = membership
    end
  end

  class SimpleObserver
    def initialize(fn)
      @fn = fn
    end

    def update(value)
      @fn.call(value)
    end

    def self.adding_to_queue(q)
      new(->(value) { q << value })
    end
  end
end
