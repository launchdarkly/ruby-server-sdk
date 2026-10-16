require "ldclient-rb/interfaces"
require "ldclient-rb/impl/data_store"
require "ldclient-rb/impl/file_data"

require "concurrent"

module LaunchDarkly
  #
  # An override source for tests. It supplies the given definitions when started, keeps the sink
  # so that a test can supply further snapshots, and records its lifecycle. It acts as its own
  # builder so that it can be passed to ConfigBuilder#overrides directly.
  #
  class TestOverrideSource
    include Interfaces::Overrides::OverrideSource

    attr_reader :sink, :build_args

    def initialize(flags = [], segments = [])
      @flags = flags
      @segments = segments
      @sink = nil
      @started = Concurrent::AtomicBoolean.new(false)
      @stopped = Concurrent::AtomicBoolean.new(false)
      @build_args = nil
    end

    def build(sdk_key, config)
      @build_args = [sdk_key, config]
      self
    end

    def start(sink)
      @started.make_true
      @sink = sink
      sink.set_overrides(@flags, @segments)
    end

    def stop
      @stopped.make_true
    end

    def started?
      @started.value
    end

    def stopped?
      @stopped.value
    end

    # Supplies a new snapshot through the sink the SDK passed to start.
    def update(flags, segments = [])
      @sink.set_overrides(flags, segments)
    end
  end

  #
  # An initializer for tests that delivers the given flag and segment data as a full transfer with a
  # defined selector, which is what makes the client report that it is initialized.
  #
  class TestDataInitializer
    include Interfaces::DataSystem::Initializer

    def initialize(flags: {}, segments: {}, selector: Interfaces::DataSystem::Selector.new(state: "test", version: 1))
      @flags = flags
      @segments = segments
      @selector = selector
    end

    def build(_sdk_key, _config)
      self
    end

    def name
      "TestDataInitializer"
    end

    def fetch(_selector_store)
      builder = Interfaces::DataSystem::ChangeSetBuilder.new
      builder.start(Interfaces::DataSystem::IntentCode::TRANSFER_FULL)
      @flags.each do |key, flag|
        builder.add_put(Interfaces::DataSystem::ObjectKind::FLAG, key.to_sym, flag[:version] || 1, flag)
      end
      @segments.each do |key, segment|
        builder.add_put(Interfaces::DataSystem::ObjectKind::SEGMENT, key.to_sym, segment[:version] || 1, segment)
      end
      basis = Interfaces::DataSystem::Basis.new(change_set: builder.finish(@selector), persist: false)
      Interfaces::DataSystem::FetchResult.new(result: Result.success(basis))
    end
  end

  #
  # A synchronizer for tests that never delivers anything. With it configured, the client has a data
  # source but no data, so it applies its not-initialized handling instead of treating the empty
  # store as cached data.
  #
  class HangingSynchronizer
    include Interfaces::DataSystem::Synchronizer

    def initialize
      @stop_event = Concurrent::Event.new
    end

    def build(_sdk_key, _config)
      self
    end

    def name
      "HangingSynchronizer"
    end

    def sync(_selector_store)
      @stop_event.wait
    end

    def stop
      @stop_event.set
    end
  end

  #
  # A flag change listener for tests that collects the changed keys.
  #
  class CollectingFlagChangeListener
    def initialize
      @changes = Queue.new
    end

    def update(flag_change)
      @changes << flag_change.key
    end

    # Waits for the next change and returns its key, or nil after the timeout.
    def next_key(timeout = 2)
      @changes.pop(timeout: timeout)
    end

    # Collects every key that arrives within the settle time after the first one.
    def collect(timeout = 2, settle = 0.3)
      keys = []
      first = next_key(timeout)
      return keys if first.nil?

      keys << first
      loop do
        key = next_key(settle)
        break if key.nil?

        keys << key
      end
      keys.sort
    end
  end
end
