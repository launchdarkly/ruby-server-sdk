# frozen_string_literal: true

require "ldclient-rb/impl/file_data/document"
require "ldclient-rb/impl/file_data/merge"
require "ldclient-rb/impl/util"

require "digest"

module LaunchDarkly
  module Impl
    module FileData
      #
      # Owns the reload cycle for a set of data files. It serializes reloads, debounces change
      # signals, retains the last good result on failure (by not calling `apply`), retries after
      # failures, and skips no-op applications.
      #
      # The worker thread starts on the first {#reload_now} or {#trigger} call rather than in the
      # constructor. A reloader can be constructed by a component whose lifecycle never uses it,
      # and construction alone must not leak a thread.
      #
      # @private
      #
      class Reloader
        # A settle window long enough to coalesce the burst of change notifications produced by a
        # single file edit, and short enough to stay responsive. In seconds.
        DEFAULT_DEBOUNCE_DELAY = 0.1

        # Bounds how long a failed reload can go uncorrected when no further change notification
        # arrives, for example when the failure came from reading a file mid-write. Reading a local
        # file is cheap, so this can be short. In seconds.
        DEFAULT_RETRY_DELAY = 1.0

        #
        # @param paths [Array<String>] the files to load, already resolved to absolute paths. The
        #   order is significant: it determines which file wins under the duplicate keys handling.
        # @param logger [Logger]
        # @param apply [#call] invoked with each successfully merged {MergeResult}. Calls are
        #   serialized, so implementations do not need their own synchronization against other
        #   reloads. `apply` and `on_error` must not call back into {#stop}.
        # @param on_error [#call, nil] invoked with the error when a reload fails, once per distinct
        #   failure. With automatic retries, repeats of an identical failure do not re-invoke it. A
        #   success re-arms it. The error is a {ReadError} when a file could not be read or parsed,
        #   or a {MergeError} otherwise. The reloader logs failures itself.
        # @param duplicate_keys_handling [Symbol] one of the {DuplicateKeysHandling} values
        # @param skip_missing_paths [Boolean] when true, a configured file that does not exist is a
        #   file with no content, and the reload succeeds with the data of the files that exist.
        #   When false, a missing file fails the reload like any other read error.
        # @param debounce_delay [Numeric] seconds to wait after a {#trigger} call for further calls
        #   to settle before reloading. If zero or negative, each trigger reloads at once.
        # @param retry_delay [Numeric] seconds to wait after a failed reload before retrying
        #   automatically. If zero or negative, there is no automatic retry.
        # @param skip_unchanged [Boolean] if true, `apply` is not invoked when the files' raw
        #   contents are byte-identical to the last successfully applied contents.
        # @param next_version [#call, nil] if given, invoked once per reload and the returned
        #   version is stamped on every entry.
        #
        def initialize(paths:, logger:, apply:, on_error: nil,
                       duplicate_keys_handling: DuplicateKeysHandling::FAIL,
                       skip_missing_paths: false,
                       debounce_delay: DEFAULT_DEBOUNCE_DELAY,
                       retry_delay: DEFAULT_RETRY_DELAY,
                       skip_unchanged: false,
                       next_version: nil)
          @paths = paths
          @logger = logger
          @apply = apply
          @on_error = on_error
          @duplicate_keys_handling = duplicate_keys_handling
          @skip_missing_paths = skip_missing_paths
          @debounce_delay = debounce_delay
          @retry_delay = retry_delay
          @skip_unchanged = skip_unchanged
          @next_version = next_version

          # Guards the scheduling state below and wakes the worker.
          @mutex = Mutex.new
          @cond = ConditionVariable.new
          @worker = nil
          @stopped = false
          @trigger_pending = false
          @retry_requested = false
          @debounce_deadline = nil
          @retry_deadline = nil

          # Serializes the actual load work between reload_now and the worker.
          @reload_mutex = Mutex.new
          @last_good_digest = nil
          @last_error_message = nil
        end

        #
        # Synchronously loads the files and applies the result, or reports the failure. Use it for
        # the initial load. A failure here schedules the same automatic retry as a failed
        # triggered reload.
        #
        # @return [Boolean] true if the load succeeded
        #
        def reload_now
          ensure_started
          ok = reload(retrying: false)
          request_retry unless ok
          ok
        end

        #
        # Signals that the files may have changed and a reload should happen after the debounce
        # delay. It never blocks. Signals that arrive while a reload is already pending are
        # coalesced.
        #
        def trigger
          ensure_started
          @mutex.synchronize do
            @trigger_pending = true
            @cond.signal
          end
        end

        #
        # Stops the reloader. It does not wait for a reload that is already in progress. A reload
        # wedged in a blocking file read must not be able to wedge shutdown. Such a reload can
        # still deliver its result through `apply` or `on_error` shortly after this method
        # returns, and consumers tolerate that. A reload that has not yet reached its callbacks
        # when this method is called does not invoke them.
        #
        def stop
          @mutex.synchronize do
            @stopped = true
            @cond.broadcast
          end
        end

        private def ensure_started
          @mutex.synchronize do
            return if @stopped || !@worker.nil?

            @worker = Thread.new { run }
            @worker.name = "LD/FileDataReloader"
          end
        end

        private def request_retry
          return unless @retry_delay > 0

          @mutex.synchronize do
            @retry_requested = true
            @cond.signal
          end
        end

        private def run
          loop do
            action = next_action
            break if action == :stop

            if action == :reload
              @logger.info { "[LDClient] Reloading flag data after detecting a change" }
            else
              @logger.debug { "[LDClient] Retrying flag data load after earlier failure" }
            end
            ok = reload(retrying: action == :retry)
            @mutex.synchronize do
              # A pending retry is superseded by this reload. The reload either succeeded, or it
              # failed and arms a fresh retry here.
              @retry_deadline = ok || @retry_delay <= 0 ? nil : monotonic_now + @retry_delay
            end
          end
        rescue => e
          Util.log_exception(@logger, "Unexpected error in file data reloader", e)
        end

        #
        # Waits until a reload is due. Returns :reload for a change-triggered reload, :retry for
        # an automatic retry, or :stop.
        #
        private def next_action
          @mutex.synchronize do
            loop do
              return :stop if @stopped

              now = monotonic_now
              if @trigger_pending
                @trigger_pending = false
                return :reload if @debounce_delay <= 0

                @debounce_deadline = now + @debounce_delay
              end
              if @retry_requested
                # A synchronous reload_now failed. Arm the retry without reloading again at once.
                # An already armed retry keeps its earlier deadline.
                @retry_requested = false
                @retry_deadline ||= now + @retry_delay
              end
              if !@debounce_deadline.nil? && now >= @debounce_deadline
                @debounce_deadline = nil
                return :reload
              end
              if !@retry_deadline.nil? && now >= @retry_deadline
                @retry_deadline = nil
                return :retry
              end

              deadlines = [@debounce_deadline, @retry_deadline].compact
              timeout = deadlines.empty? ? nil : [deadlines.min - now, 0].max
              @cond.wait(@mutex, timeout)
            end
          end
        end

        #
        # Performs one full load of all configured files and returns whether it succeeded. That
        # decides whether a retry is armed, so a skipped no-op application counts as success. The
        # whole set is re-read on every reload: entries are combined across files in order, so a
        # change to one file can alter which file wins for a key.
        #
        private def reload(retrying: false)
          @reload_mutex.synchronize do
            # A trigger already queued when stop was called can still reach here.
            return true if stopped?

            documents = []
            files = []
            digest = Digest::SHA256.new
            @paths.each do |path|
              begin
                # One read feeds both the digest and the parse, so the skip-unchanged digest can
                # never disagree with the content that was applied.
                content = FileData.read_file(path)
              rescue ReadError => e
                if e.missing && @skip_missing_paths
                  @logger.debug { "[LDClient] File #{path} does not exist; it contributes no data" }
                  files << FileSummary.new(path, false, 0, 0)
                  next
                end
                return record_failure(e)
              end
              digest << content << "\0"
              begin
                documents << FileData.parse_file(path, content)
              rescue ReadError => e
                return record_failure(e)
              end
              files << FileSummary.new(path, true, 0, 0)
            end

            begin
              merged = FileData.merge(documents,
                duplicate_keys_handling: @duplicate_keys_handling,
                logger: @logger,
                version: @next_version&.call)
            rescue => e
              return record_failure(e)
            end

            # Documents are the present files in order. Copy their counts onto the file summaries.
            document_index = 0
            files.each do |file|
              next unless file.present

              summary = merged.documents[document_index]
              file.flags = summary.flags
              file.segments = summary.segments
              document_index += 1
            end
            merged.files = files

            # stop may have been called while the files were being read. Deliver nothing then.
            return true if stopped?

            # A success right after a failure must apply even when the content is unchanged since
            # the last success. The consumer heard about the failure through on_error and may
            # have moved to an interrupted state. Only apply tells it that things are good again.
            recovering = !@last_error_message.nil?
            @last_error_message = nil
            hexdigest = digest.hexdigest
            return true if @skip_unchanged && !recovering && hexdigest == @last_good_digest

            @last_good_digest = hexdigest
            @apply.call(merged)
            true
          end
        end

        private def record_failure(error)
          # stop may have been called while the files were being read. Deliver nothing then, and
          # report success so that no retry is armed.
          return true if stopped?

          # With automatic retries, a persistent failure would repeat the same log entry and the
          # same callback on every attempt. Repeats of an identical failure are logged at debug
          # level and do not re-invoke on_error.
          message = error.message
          if message == @last_error_message
            @logger.debug { "[LDClient] Unable to load flags: #{message}" }
            return false
          end

          @last_error_message = message
          @logger.error { "[LDClient] Unable to load flags: #{message}" }
          @on_error&.call(error)
          false
        end

        private def stopped?
          @mutex.synchronize { @stopped }
        end

        private def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
