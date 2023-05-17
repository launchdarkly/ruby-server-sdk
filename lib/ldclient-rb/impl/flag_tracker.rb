require "concurrent"
require "ldclient-rb/interfaces"
require "forwardable"

module LaunchDarkly
  module Impl
    class FlagTracker
      include LaunchDarkly::Interfaces::FlagTracker

      extend Forwardable
      def_delegators :@broadcaster, :add_listener, :remove_listener

      def initialize(broadcaster, eval_fn)
        @broadcaster = broadcaster
        @eval_fn = eval_fn
      end

      def add_flag_value_change_listener(key, context, listener)
        flag_change_listener = FlagValueChangeAdapter.new(key, context, listener, @eval_fn)
        add_listener(flag_change_listener)

        flag_change_listener
      end

      #
      # An adapter which turns a normal flag change listener into a flag value change listener.
      #
      class FlagValueChangeAdapter
        # @param [Symbol] flag_key
        # @param [LaunchDarkly::LDContext] context
        # @param [#update] listener
        # @param [#call] eval_fn
        def initialize(flag_key, context, listener, eval_fn)
          @flag_key = flag_key
          @context = context
          @listener = listener
          @eval_fn = eval_fn
          @value = Concurrent::AtomicReference.new(@eval_fn.call(@flag_key, @context))
        end

        #
        # @param [LaunchDarkly::Interfaces::FlagChange] flag_change
        #
        def update(flag_change)
          return unless flag_change.key == @flag_key

          new_eval = @eval_fn.call(@flag_key, @context)
          old_eval = @value.get_and_set(new_eval)

          return if new_eval == old_eval

          @listener.update(
            LaunchDarkly::Interfaces::FlagValueChange.new(@flag_key, old_eval, new_eval))
        end
      end
    end
  end
end
