require "capturing_logger"
require "mock_components"
require "spec_helper"

module LaunchDarkly
  describe "LDClient fork detection" do
    let(:logger) { CapturingLogger.new }
    let(:context) { basic_context }
    let(:warning_pattern) { /forked after the LDClient was created/ }

    # Make Process.pid report a pid other than the one recorded by the client. The client is created before this
    # stub is applied, so the client sees the real pid as the owner and the stubbed pid as a child.
    def pretend_forked
      real_pid = Process.pid
      allow(Process).to receive(:pid).and_return(real_pid + 1)
    end

    def fork_warnings(logger)
      logger.output.lines.grep(warning_pattern)
    end

    context "when the pid has not changed" do
      it "does not warn" do
        with_client(test_config(logger: logger)) do |client|
          client.variation("flag", context, false)
          client.identify(context)
          client.track("event", context)
          client.all_flags_state(context)
          client.flush
        end
        expect(fork_warnings(logger)).to be_empty
      end
    end

    context "when the pid has changed" do
      it "warns on variation" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          client.variation("flag", context, false)
          expect(fork_warnings(logger).length).to eq(1)
        end
      end

      it "warns on variation_detail" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          client.variation_detail("flag", context, false)
          expect(fork_warnings(logger).length).to eq(1)
        end
      end

      it "warns on all_flags_state" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          client.all_flags_state(context)
          expect(fork_warnings(logger).length).to eq(1)
        end
      end

      it "warns on migration_variation" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          client.migration_variation("flag", context, LaunchDarkly::Migrations::STAGE_OFF)
          expect(fork_warnings(logger).length).to eq(1)
        end
      end

      it "warns on identify" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          client.identify(context)
          expect(fork_warnings(logger).length).to eq(1)
        end
      end

      it "warns on track" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          client.track("event", context)
          expect(fork_warnings(logger).length).to eq(1)
        end
      end

      it "warns on flush" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          client.flush
          expect(fork_warnings(logger).length).to eq(1)
        end
      end

      it "warns on close" do
        client = LDClient.new(sdk_key, test_config(logger: logger))
        pretend_forked
        client.close
        expect(fork_warnings(logger).length).to eq(1)
      end

      it "warns only once per process across many calls" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          5.times { client.variation("flag", context, false) }
          client.identify(context)
          client.track("event", context)
          client.all_flags_state(context)
          client.flush
        end
        expect(fork_warnings(logger).length).to eq(1)
      end

      it "warns only once when many threads evaluate at the same time" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          threads = Array.new(16) do
            Thread.new { 50.times { client.variation("flag", context, false) } }
          end
          threads.each(&:join)
        end
        expect(fork_warnings(logger).length).to eq(1)
      end

      it "names postfork and says flag updates and analytics events do not work" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          client.variation("flag", context, false)
        end
        warning = fork_warnings(logger).first
        expect(warning).to include("LDClient#postfork")
        expect(warning).to include("flag updates and analytics events will not work")
      end

      it "warns in LDD mode when events are enabled" do
        config = Config.new(use_ldd: true, send_events: true, logger: logger)
        with_client(config) do |client|
          pretend_forked
          client.variation("flag", context, false)
        end
        expect(fork_warnings(logger).length).to eq(1)
      end

      it "does not warn in LDD mode when events are disabled" do
        config = Config.new(use_ldd: true, send_events: false, logger: logger)
        with_client(config) do |client|
          pretend_forked
          client.variation("flag", context, false)
          client.flush
        end
        expect(fork_warnings(logger)).to be_empty
      end

      it "does not warn when offline" do
        config = Config.new(offline: true, logger: logger)
        with_client(config) do |client|
          pretend_forked
          client.variation("flag", context, false)
          client.identify(context)
          client.track("event", context)
          client.all_flags_state(context)
          client.flush
        end
        expect(fork_warnings(logger)).to be_empty
      end

      it "stops warning after postfork" do
        with_client(test_config(logger: logger)) do |client|
          pretend_forked
          client.variation("flag", context, false)
          expect(fork_warnings(logger).length).to eq(1)

          client.postfork(0)
          client.variation("flag", context, false)
          client.flush
        end
        expect(fork_warnings(logger).length).to eq(1)
      end

      it "warns again in a second forked process even if the first one already warned" do
        with_client(test_config(logger: logger)) do |client|
          real_pid = Process.pid
          allow(Process).to receive(:pid).and_return(real_pid + 1)
          client.variation("flag", context, false)
          expect(fork_warnings(logger).length).to eq(1)

          # The "already warned" state is copied into a grandchild on fork. It must still warn there.
          allow(Process).to receive(:pid).and_return(real_pid + 2)
          client.variation("flag", context, false)
          expect(fork_warnings(logger).length).to eq(2)
        end
      end
    end

    context "with a real fork" do
      def fork_supported?
        RUBY_ENGINE != "jruby" && Process.respond_to?(:fork)
      end

      it "warns in the child and stops after postfork" do
        skip "fork is not supported on this platform" unless fork_supported?

        client = LDClient.new(sdk_key, test_config(logger: logger))
        begin
          reader, writer = IO.pipe
          pid = fork do
            reader.close
            child_logger = CapturingLogger.new
            # Give the inherited client a fresh logger so the child output is easy to read.
            client.instance_variable_get(:@config).instance_variable_set(:@logger, child_logger)

            client.variation("flag", context, false)
            client.variation("flag", context, false)
            before_postfork = child_logger.output.lines.grep(warning_pattern).length

            client.postfork(0)
            client.variation("flag", context, false)
            after_postfork = child_logger.output.lines.grep(warning_pattern).length

            writer.write("#{before_postfork},#{after_postfork}")
            writer.close
            exit!(0)
          end
          writer.close
          output = reader.read
          reader.close
          Process.wait(pid)

          expect(output).to eq("1,1")
          # The parent process was not forked, so it must not warn.
          client.variation("flag", context, false)
          expect(fork_warnings(logger)).to be_empty
        ensure
          client.close
        end
      end
    end
  end
end
