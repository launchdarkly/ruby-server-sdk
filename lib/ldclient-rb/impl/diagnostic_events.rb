require "ldclient-rb/impl/util"

require "rbconfig"
require "securerandom"

module LaunchDarkly
  module Impl
    class DiagnosticAccumulator
      def self.create_diagnostic_id(sdk_key)
        {
          diagnosticId: SecureRandom.uuid,
          sdkKeySuffix: sdk_key[-6..-1] || sdk_key,
        }
      end

      def initialize(diagnostic_id)
        @id = diagnostic_id
        @lock = Mutex.new
        self.reset(Util.current_time_millis)
      end

      def reset(time)
        @data_since_date = time
        @stream_inits = []
      end

      def create_init_event(config)
        {
          kind: 'diagnostic-init',
          creationDate: Util.current_time_millis,
          id: @id,
          configuration: DiagnosticAccumulator.make_config_data(config),
          sdk: DiagnosticAccumulator.make_sdk_data(config),
          platform: DiagnosticAccumulator.make_platform_data,
        }
      end

      def record_stream_init(timestamp, failed, duration_millis)
        @lock.synchronize do
          @stream_inits.push({ timestamp: timestamp, failed: failed, durationMillis: duration_millis })
        end
      end

      def create_periodic_event_and_reset(dropped_events, deduplicated_users, events_in_last_batch)
        previous_stream_inits = @lock.synchronize do
          si = @stream_inits
          @stream_inits = []
          si
        end

        current_time = Util.current_time_millis
        event = {
          kind: 'diagnostic',
          creationDate: current_time,
          id: @id,
          dataSinceDate: @data_since_date,
          droppedEvents: dropped_events,
          deduplicatedUsers: deduplicated_users,
          eventsInLastBatch: events_in_last_batch,
          streamInits: previous_stream_inits,
        }
        @data_since_date = current_time
        event
      end

      def self.make_config_data(config)
        ret = {
          allAttributesPrivate: config.all_attributes_private,
          connectTimeoutMillis: self.seconds_to_millis(config.connect_timeout),
          customBaseURI: config.base_uri != Config.default_base_uri,
          customEventsURI: config.events_uri != Config.default_events_uri,
          customStreamURI: config.stream_uri != Config.default_stream_uri,
          diagnosticRecordingIntervalMillis: self.seconds_to_millis(config.diagnostic_recording_interval),
          eventsCapacity: config.capacity,
          eventsFlushIntervalMillis: self.seconds_to_millis(config.flush_interval),
          pollingIntervalMillis: self.seconds_to_millis(config.poll_interval),
          socketTimeoutMillis: self.seconds_to_millis(config.read_timeout),
          streamingDisabled: !config.stream?,
          userKeysCapacity: config.context_keys_capacity,
          userKeysFlushIntervalMillis: self.seconds_to_millis(config.context_keys_flush_interval),
          usingProxy: ENV.has_key?('http_proxy') || ENV.has_key?('https_proxy') || ENV.has_key?('HTTP_PROXY') || ENV.has_key?('HTTPS_PROXY'),
          usingRelayDaemon: config.use_ldd?,
        }
        ret
      end

      def self.make_sdk_data(config)
        ret = {
          name: 'ruby-server-sdk',
          version: LaunchDarkly::VERSION,
        }
        if config.wrapper_name
          ret[:wrapperName] = config.wrapper_name
          ret[:wrapperVersion] = config.wrapper_version
        end
        ret
      end

      def self.make_platform_data
        conf = RbConfig::CONFIG
        {
          name: 'ruby',
          osArch: conf['host_cpu'],
          osName: self.normalize_os_name(conf['host_os']),
          osVersion: 'unknown', # there seems to be no portable way to detect this in Ruby
          rubyVersion: conf['ruby_version'],
          rubyImplementation: Object.constants.include?(:RUBY_ENGINE) ? RUBY_ENGINE : 'unknown',
        }
      end

      def self.normalize_os_name(name)
        case name
        when /linux|arch/i
          'Linux'
        when /darwin/i
          'MacOS'
        when /mswin|windows/i
          'Windows'
        else
          name
        end
      end

      def self.seconds_to_millis(s)
        (s * 1000).to_i
      end
    end
  end
end
