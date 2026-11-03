# frozen_string_literal: true

require "ldclient-rb/impl/file_data/document"
require "ldclient-rb/impl/file_data/merge"
require "ldclient-rb/impl/file_data/poller"

require "digest"

module LaunchDarkly
  module Impl
    module FileData
      #
      # Owns the reload cycle for a set of data files. It serializes reloads, debounces change
      # signals, retains the last good result on failure (by not calling `apply`), retries after
      # failures, holds back a file that was emptied before applying it, and skips no-op
      # applications.
      #
      # Applications and editors rewrite files in place: they truncate the file, then write the new
      # content. A load in between finds the file empty, or, for YAML, can find only a comment or
      # "---", which the YAML parser reads as nothing. Whether a file with no entries is valid
      # depends on its format (see {Document.parse}), so a parser cannot tell an emptied file from
      # one in the middle of a rewrite. So a load that finds a file with no content (empty, white
      # space, or YAML that is only a null), while the data currently applied has content from that
      # file, holds the file back: it reads the other files, so that files emptied together are
      # held back together, then keeps the current data and arms the retry, without reporting a
      # failure. A file that cannot be read or parsed still fails the load. A YAML document such as
      # `{}` is content, and is applied at once.
      #
      # A file is held back until it has stayed so, without being written, for the retry delay,
      # counted from the load that read it. A change of its state (its modification time and size,
      # read through any symbolic link) means it was written since a load last found it so, for
      # example rewritten and truncated again between two loads, so the delay starts over. Each file
      # is held back for at most five retry delays from the first load that held it back. The bound
      # goes on across reads that find the file with content, and starts over only at a load that
      # holds nothing back, whether that load applies, is skipped as unchanged, or fails, for each
      # file that load read. So a file that keeps being rewritten, or files rewritten in turn, cannot
      # hold the data back without end. The retry that a hold arms comes when the first held file's
      # delay or bound is over, plus a tenth of the retry delay. A file that contributed no content
      # to the data currently applied, such as a placeholder that has been empty from the start, a
      # file that was missing, or a file whose emptying has been applied, is parsed at once. So is every file when there are no
      # automatic retries, because nothing would read it again. After the delay, an empty JSON file
      # fails to parse and the data stays; an empty YAML file is a document with no entries.
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

        # A file is held back for at most this many retry delays from the first load that held it
        # back, until data is applied.
        MAX_HOLD_RETRY_DELAYS = 5

        # A file whose content is in effect and that loads have found with no content: since when it
        # has been so without being written, or nil once a load read it with content or found it
        # missing; its {Poller::FileState} then; and when a load first held it back, or nil.
        EmptyFile = Struct.new(:since, :state, :first_held)
        private_constant :EmptyFile

        #
        # @param paths [Array<String>] the files to load, already resolved to absolute paths. The
        #   order is significant: it determines which file wins under the duplicate keys handling.
        # @param logger [Logger]
        # @param apply [#call] invoked with each successfully merged {MergeResult}. Calls are
        #   serialized, so implementations do not need their own synchronization against other
        #   reloads. An exception from `apply` is a failed reload: it is reported through
        #   `on_error`, the result is not remembered as applied, and the reload is retried.
        #   `apply` and `on_error` must not call back into {#stop}.
        # @param on_error [#call, nil] invoked with the error when a reload fails, once per distinct
        #   failure. With automatic retries, repeats of an identical failure do not re-invoke it. A
        #   success re-arms it. The error is a {ReadError} when a file could not be read or parsed,
        #   a {MergeError} when the documents could not be combined, or the exception that `apply`
        #   raised. The reloader logs failures itself.
        # @param duplicate_keys_handling [Symbol] one of the {DuplicateKeysHandling} values
        # @param skip_missing_paths [Boolean] when true, a configured file that does not exist
        #   contributes no data, and the reload succeeds with the data of the files that exist.
        #   When false, a missing file fails the reload like any other read error.
        # @param debounce_delay [Numeric] seconds to wait after a {#trigger} call for further calls
        #   to settle before reloading. If zero or negative, each trigger reloads at once.
        # @param retry_delay [Numeric] seconds to wait after a failed reload before retrying
        #   automatically. A file whose content is in effect and that is found empty is held back
        #   for the same delay. If zero or negative, there is no automatic retry, and an empty file
        #   is parsed as it is.
        # @param skip_unchanged [Boolean] if true, `apply` is not invoked when the files' raw
        #   contents are byte-identical to the last successfully applied contents.
        # @param log_prefix [String] the prefix of every log line this reloader writes
        # @param clock [#call, nil] returns the seconds of a monotonic clock, for the time a file has
        #   been held back; nil for the system's. Scheduling always uses the system's clock.
        #
        def initialize(paths:, logger:, apply:, on_error: nil,
                       duplicate_keys_handling: DuplicateKeysHandling::FAIL,
                       skip_missing_paths: false,
                       debounce_delay: DEFAULT_DEBOUNCE_DELAY,
                       retry_delay: DEFAULT_RETRY_DELAY,
                       skip_unchanged: false,
                       log_prefix: "[LDClient]",
                       clock: nil)
          @paths = paths
          @logger = logger
          @log_prefix = log_prefix
          @apply = apply
          @on_error = on_error
          @duplicate_keys_handling = duplicate_keys_handling
          @skip_missing_paths = skip_missing_paths
          @debounce_delay = debounce_delay
          @retry_delay = retry_delay
          @skip_unchanged = skip_unchanged
          @clock = clock || method(:monotonic_now)

          # Guards the scheduling state below and wakes the worker.
          @mutex = Mutex.new
          @cond = ConditionVariable.new
          @worker = nil
          @stopped = false
          @trigger_pending = false
          @requested_retry_delay = nil
          @debounce_deadline = nil
          @retry_deadline = nil

          # Serializes the actual load work between reload_now and the worker.
          @reload_mutex = Mutex.new
          @last_good_digest = nil
          @last_error_message = nil
          # Whether each configured path contributed content to the data currently applied; the
          # EmptyFile of each path whose content is in effect and that loads have found with no
          # content since; whether the last load held a file back; and whether the load in progress
          # holds one back. Only touched while holding @reload_mutex.
          @applied_had_content = {}
          @empty_files = {}
          @read_again_pending = false
          @holding_this_load = false
          # The delay of the last retry that a load asked for. Only tests read it. Guarded by @mutex.
          @last_requested_retry_delay = nil
        end

        #
        # Synchronously loads the files and applies the result, or reports the failure. Use it for
        # the initial load. A failure here schedules the same automatic retry as a failed
        # triggered reload, and a load that holds back a file it finds empty arms the retry for when
        # the file may be read as it is.
        #
        # @return [Boolean] true if the load succeeded, false if it failed or held back an empty file
        #
        def reload_now
          ensure_started
          retry_in = reload(retrying: false)
          request_retry(retry_in) unless retry_in.nil?
          retry_in.nil?
        end

        #
        # The delay in seconds of the last retry that a load asked for, armed or not. Only tests
        # use it.
        #
        # @return [Numeric, nil]
        #
        def last_requested_retry_delay
          @mutex.synchronize { @last_requested_retry_delay }
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

        private def request_retry(delay)
          return unless @retry_delay > 0

          @mutex.synchronize do
            @last_requested_retry_delay = delay
            @requested_retry_delay = [@requested_retry_delay, delay].compact.min
            @cond.signal
          end
        end

        private def run
          loop do
            action = next_action
            break if action == :stop

            @logger.info { "#{@log_prefix} Reloading flag data after detecting a change" } if action == :reload
            retry_in = reload(retrying: action == :retry)
            @mutex.synchronize do
              # A pending retry is superseded by this reload. The reload either succeeded, or it
              # failed or held back a file and arms a fresh retry here.
              @last_requested_retry_delay = retry_in unless retry_in.nil?
              @retry_deadline = retry_in.nil? || @retry_delay <= 0 ? nil : monotonic_now + retry_in
            end
          end
        rescue => e
          @logger.error { "#{@log_prefix} Unexpected error in file data reloader: #{e.inspect}" }
          @logger.debug { "#{@log_prefix} Exception trace: #{e.backtrace}" }
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
              unless @requested_retry_delay.nil?
                # A synchronous reload_now failed or held back a file. Arm the retry without
                # reloading again at once. An already armed retry that comes sooner is kept.
                deadline = now + @requested_retry_delay
                @requested_retry_delay = nil
                @retry_deadline = [@retry_deadline, deadline].compact.min
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
        # Performs one full load of all configured files. Returns nil if it succeeded, or the
        # seconds after which to retry if it failed or held back a file. A skipped no-op application
        # counts as success. The whole set is re-read on every reload: entries are combined across
        # files in order, so a change to one file can alter which file wins for a key.
        #
        private def reload(retrying: false)
          @reload_mutex.synchronize do
            # A trigger already queued when stop was called can still reach here.
            return nil if stopped?

            if retrying
              if @read_again_pending
                @logger.debug { "#{@log_prefix} Reading flag data again after a file was found empty" }
              else
                @logger.debug { "#{@log_prefix} Retrying flag data load after earlier failure" }
              end
            end
            @read_again_pending = false
            @holding_this_load = false
            # The files that the load read and did not hold back, with whether each had content.
            had_content = {}
            retry_in = load_files(had_content)
            unless @holding_this_load
              # A load that holds nothing back, whether it applies, is skipped or fails, starts the
              # bound over for every file that it read: such a file is no longer held back, so its
              # next rewrite is a new one. A file that the load did not get to keeps its bound.
              had_content.each_key do |path|
                empty = @empty_files[path]
                empty.first_held = nil unless empty.nil?
              end
            end
            retry_in
          end
        end

        # The body of {#reload}, while holding @reload_mutex.
        private def load_files(had_content)
          documents = []
          files = []
          held = []
          digest = Digest::SHA256.new
          @paths.each do |path|
            begin
              # One read feeds both the digest and the parse, so the skip-unchanged digest can never
              # disagree with the content that was applied.
              content = FileData.read_file(path)
            rescue ReadError => e
              # A missing file is not empty, so its delay starts again when it is found empty. Its
              # bound goes on.
              @empty_files[path].since = nil if e.missing && @empty_files.key?(path)
              if e.missing && @skip_missing_paths
                @logger.debug { "#{@log_prefix} File #{path} does not exist; it contributes no data" }
                had_content[path] = false
                files << FileSummary.new(path, false, 0, 0)
                next
              end
              return record_failure(e)
            end
            # A file with no content, or YAML that the parser reads as nothing, such as only a
            # comment, has no entries. A read can see that much of a file that is being written.
            # Content with no JSON document is only parsed when the file is not held back, and then
            # fails to parse.
            document = nil
            has_content = !FileData.blank?(content)
            if has_content
              begin
                document = FileData.parse_file(path, content)
              rescue ReadError => e
                return record_failure(e)
              end
              has_content = !document.equal?(Document::NONE)
            end
            if has_content
              # Its delay starts again when it is found empty. Its bound goes on, so that files
              # rewritten in turn stay bounded.
              @empty_files[path].since = nil if @empty_files.key?(path)
            elsif hold_back?(path, @clock.call)
              # The clock is read after this file's own read, so a slow read of another file does
              # not shorten its delay.
              # The other files are still read, so that files emptied together start their delays
              # in the same load.
              @holding_this_load = true
              held << path
              next
            end
            had_content[path] = has_content

            digest << content << "\0"
            if document.nil?
              begin
                document = FileData.parse_file(path, content)
              rescue ReadError => e
                return record_failure(e)
              end
            end
            documents << document
            files << FileSummary.new(path, true, 0, 0)
          end
          return hold_back(held, @clock.call) unless held.empty?

          begin
            merged = FileData.merge(documents,
              duplicate_keys_handling: @duplicate_keys_handling,
              logger: @logger)
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
          return nil if stopped?

          # A success right after a failure must apply even when the content is unchanged since the
          # last success. The consumer heard about the failure through on_error and may have moved
          # to an interrupted state. Only apply tells it that things are good again.
          recovering = !@last_error_message.nil?
          hexdigest = digest.hexdigest
          if @skip_unchanged && !recovering && hexdigest == @last_good_digest
            # The digest covers only the content of the files that are present, so the same
            # content can now come from another file.
            remember_applied(had_content)
            return nil
          end

          # Nothing is remembered until the consumer has accepted the result. A result that apply
          # rejects must not become the baseline that skip-unchanged compares against, and must not
          # count as a recovery.
          begin
            @apply.call(merged)
          rescue => e
            return record_failure(e)
          end
          @last_error_message = nil
          @last_good_digest = hexdigest
          remember_applied(had_content)
          nil
        end

        # Records what each file contributed to the data now in effect. The holds of the files start
        # over.
        private def remember_applied(had_content)
          @applied_had_content = had_content
          @empty_files.clear
        end

        #
        # Decides whether a load that found a file with no content holds it back, because it may be
        # in the middle of an in-place rewrite, and records since when it has been so. `now` is read
        # after the file's own read.
        #
        private def hold_back?(path, now)
          return false if @retry_delay <= 0 || !@applied_had_content[path]

          state = Poller.observe(path)
          empty = (@empty_files[path] ||= EmptyFile.new(nil, nil, nil))
          if empty.since.nil? || empty.state != state
            # Found empty for the first time since it had content, or written since a load last
            # found it so: a new rewrite.
            empty.since = now
            empty.state = state
          end
          # After the delay the file is parsed. The entry stays, so later loads keep parsing it until
          # it has content. Its bound starts over only at a load that holds nothing back.
          return false if now - empty.since >= @retry_delay
          return false if !empty.first_held.nil? && now - empty.first_held >= MAX_HOLD_RETRY_DELAYS * @retry_delay

          empty.first_held ||= now
          true
        end

        #
        # Holds back a load that found files with no content. The current data stays and no failure
        # is reported. Returns when to retry: when the delay or the bound of the first of the files
        # is over, plus a tenth of the retry delay, so that a retry that comes a little early still
        # finds it over.
        #
        private def hold_back(paths, now)
          # stop may have been called while the files were being read. Arm no retry.
          return nil if stopped?

          @read_again_pending = true
          retry_at = nil
          paths.each do |path|
            @logger.debug do
              "#{@log_prefix} File #{path} is empty, possibly while it is being rewritten; reading it again before applying it"
            end
            empty = @empty_files[path]
            over = [empty.since + @retry_delay, empty.first_held + MAX_HOLD_RETRY_DELAYS * @retry_delay].min
            retry_at = over if retry_at.nil? || over < retry_at
          end
          [retry_at - now, 0].max + @retry_delay / 10.0
        end

        private def record_failure(error)
          # stop may have been called while the files were being read. Deliver nothing then, and
          # arm no retry.
          return nil if stopped?

          # With automatic retries, a persistent failure would repeat the same log entry and the
          # same callback on every attempt. Repeats of an identical failure are logged at debug
          # level and do not re-invoke on_error.
          message = error.message
          if message == @last_error_message
            @logger.debug { "#{@log_prefix} Unable to load flags: #{message}" }
            return @retry_delay
          end

          @last_error_message = message
          @logger.error { "#{@log_prefix} Unable to load flags: #{message}" }
          @on_error&.call(error)
          @retry_delay
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
