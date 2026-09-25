# frozen_string_literal: true

require "ldclient-rb/impl/file_data"
require "ldclient-rb/interfaces/overrides"

module LaunchDarkly
  module Impl
    module Integrations
      #
      # The file-based override source. It reads flag and segment overrides from one or more local
      # files and reloads them as the files change. See
      # {LaunchDarkly::Integrations::FileData.override_source} for the public API and its options.
      #
      # Flag overrides are currently experimental and subject to change.
      #
      # @private
      #
      class FileOverrideSource
        include LaunchDarkly::Interfaces::Overrides::OverrideSource

        LOG_PREFIX = "[LDClient] FileOverrideSource:"

        #
        # @param paths [Array<String>] absolute file paths, in precedence order
        # @param duplicate_keys_handling [Symbol] `:fail` or `:ignore`
        # @param change_detection [Symbol] `:polling` or `:watching`
        # @param poll_interval [Numeric] seconds between examinations in polling mode
        # @param logger [Logger]
        #
        def initialize(paths:, duplicate_keys_handling:, change_detection:, poll_interval:, logger:)
          @paths = paths
          @duplicate_keys_handling = duplicate_keys_handling
          @change_detection = change_detection
          @poll_interval = poll_interval
          @logger = logger
          @lock = Mutex.new
          @reloader = nil
          @change_detector = nil
          @stopped = false
        end

        # @return [Array<String>]
        attr_reader :paths

        # @return [Symbol]
        attr_reader :duplicate_keys_handling

        # @return [Symbol]
        attr_reader :change_detection

        # @return [Numeric]
        attr_reader :poll_interval

        #
        # Performs the initial load synchronously, so overrides present in the files are in effect
        # when this method returns, then starts change detection. A file that does not exist yet
        # contributes no overrides. A file that cannot be read or parsed is not fatal: the client
        # runs with the last good overrides, the failure is logged, and the retry plus the change
        # signal recover once the file is readable.
        #
        # (see LaunchDarkly::Interfaces::Overrides::OverrideSource#start)
        #
        def start(sink)
          @lock.synchronize do
            return if @stopped

            @reloader = FileData::Reloader.new(
              paths: @paths,
              logger: @logger,
              log_prefix: LOG_PREFIX,
              duplicate_keys_handling: @duplicate_keys_handling,
              skip_missing_paths: true,
              skip_unchanged: true,
              off_value_flags: true,
              apply: lambda do |merged|
                sink.set_overrides(merged.flags.values, merged.segments.values)
                log_overrides_in_effect(merged)
              end
            )
          end

          @reloader.reload_now

          @lock.synchronize do
            return if @stopped

            trigger = @reloader.method(:trigger)
            @change_detector =
              if @change_detection == :watching
                FileData::Watcher.new(@paths, trigger, @logger)
              else
                FileData::Poller.new(@paths, @poll_interval, trigger, @logger)
              end
          end
        end

        # (see LaunchDarkly::Interfaces::Overrides::OverrideSource#stop)
        def stop
          reloader = nil
          change_detector = nil
          @lock.synchronize do
            @stopped = true
            reloader = @reloader
            change_detector = @change_detector
            @reloader = nil
            @change_detector = nil
          end
          change_detector&.stop
          reloader&.stop
        end

        #
        # Reports the overrides now in effect and the file each came from. The reloader applies a
        # snapshot only when the content changed, so this logs each change once.
        #
        # @param merged [LaunchDarkly::Impl::FileData::MergeResult]
        #
        private def log_overrides_in_effect(merged)
          details = merged.files.map do |file|
            if !file.present
              "#{file.path}: absent"
            elsif file.flags.zero? && file.segments.zero?
              "#{file.path}: no entries"
            else
              "#{file.path}: #{counts_text(file.flags, file.segments)}"
            end
          end.join("; ")

          if merged.empty?
            @logger.info { "#{LOG_PREFIX} Flag overrides: none in effect (#{details})" }
          else
            @logger.info do
              "#{LOG_PREFIX} Flag overrides in effect: #{counts_text(merged.flags.length, merged.segments.length)} (#{details})"
            end
          end
        end

        # Formats flag and segment counts, for example "2 flags, 1 segment".
        private def counts_text(flags, segments)
          parts = []
          parts << pluralize(flags, "flag") if flags > 0
          parts << pluralize(segments, "segment") if segments > 0
          parts.join(", ")
        end

        private def pluralize(count, noun)
          count == 1 ? "1 #{noun}" : "#{count} #{noun}s"
        end
      end
    end
  end
end
