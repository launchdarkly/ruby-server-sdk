require "ldclient-rb/config"
require "ldclient-rb/expiring_cache"
require "ldclient-rb/impl/repeating_task"
require "ldclient-rb/interfaces"
require "ldclient-rb/util"

require "digest"

module LaunchDarkly
  module Impl
    BigSegmentMembershipResult = Struct.new(:membership, :status)

    class BigSegmentStoreManager
      # use this as a singleton whenever a membership query returns nil; it's safe to reuse it because
      # we will never modify the membership properties after they're queried
      EMPTY_MEMBERSHIP = {}

      def initialize(big_segments_config, logger)
        @store = big_segments_config.store
        @stale_after_millis = big_segments_config.stale_after * 1000
        @status_provider = BigSegmentStoreStatusProviderImpl.new(-> { get_status })
        @logger = logger
        @last_status = nil

        unless @store.nil?
          @cache = ExpiringCache.new(big_segments_config.user_cache_size, big_segments_config.user_cache_time)
          @poll_worker = RepeatingTask.new(big_segments_config.status_poll_interval, 0, -> { poll_store_and_update_status }, logger)
          @poll_worker.start
        end
      end

      attr_reader :status_provider

      def stop
        @poll_worker.stop unless @poll_worker.nil?
        @store.stop unless @store.nil?
      end

      def get_context_membership(context_key)
        return nil unless @store
        membership = @cache[context_key]
        unless membership
          begin
            membership = @store.get_membership(BigSegmentStoreManager.hash_for_context_key(context_key))
            membership = EMPTY_MEMBERSHIP if membership.nil?
            @cache[context_key] = membership
          rescue => e
            LaunchDarkly::Util.log_exception(@logger, "Big Segment store membership query returned error", e)
            return BigSegmentMembershipResult.new(nil, BigSegmentsStatus::STORE_ERROR)
          end
        end
        poll_store_and_update_status unless @last_status
        unless @last_status.available
          return BigSegmentMembershipResult.new(membership, BigSegmentsStatus::STORE_ERROR)
        end
        BigSegmentMembershipResult.new(membership, @last_status.stale ? BigSegmentsStatus::STALE : BigSegmentsStatus::HEALTHY)
      end

      def get_status
        @last_status || poll_store_and_update_status
      end

      def poll_store_and_update_status
        new_status = Interfaces::BigSegmentStoreStatus.new(false, false) # default to "unavailable" if we don't get a new status below
        unless @store.nil?
          begin
            metadata = @store.get_metadata
            new_status = Interfaces::BigSegmentStoreStatus.new(true, !metadata || stale?(metadata.last_up_to_date))
          rescue => e
            LaunchDarkly::Util.log_exception(@logger, "Big Segment store status query returned error", e)
          end
        end
        @last_status = new_status
        @status_provider.update_status(new_status)

        new_status
      end

      def stale?(timestamp)
        !timestamp || ((Impl::Util.current_time_millis - timestamp) >= @stale_after_millis)
      end

      def self.hash_for_context_key(context_key)
        Digest::SHA256.base64digest(context_key)
      end
    end

    #
    # Default implementation of the BigSegmentStoreStatusProvider interface.
    #
    # There isn't much to this because the real implementation is in BigSegmentStoreManager - we pass in a lambda
    # that allows us to get the current status from that class. Also, the standard Observer methods such as
    # add_observer are provided for us because BigSegmentStoreStatusProvider mixes in Observer, so all we need to
    # to do make notifications happen is to call the Observer methods "changed" and "notify_observers".
    #
    class BigSegmentStoreStatusProviderImpl
      include LaunchDarkly::Interfaces::BigSegmentStoreStatusProvider

      def initialize(status_fn)
        @status_fn = status_fn
        @last_status = nil
      end

      def status
        @status_fn.call
      end

      def update_status(new_status)
        if !@last_status || new_status != @last_status
          @last_status = new_status
          changed
          notify_observers(new_status)
        end
      end
    end
  end
end
