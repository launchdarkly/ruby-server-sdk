module LaunchDarkly
  module Impl
    # A simple thread safe generic unbounded resource pool abstraction
    class UnboundedPool
      def initialize(instance_creator, instance_destructor)
        @pool = Array.new
        @lock = Mutex.new
        @instance_creator = instance_creator
        @instance_destructor = instance_destructor
      end

      def acquire
        @lock.synchronize {
          if @pool.length == 0
            @instance_creator.call()
          else
            @pool.pop()
          end
        }
      end

      def release(instance)
        @lock.synchronize { @pool.push(instance) }
      end

      def dispose_all
        @lock.synchronize {
          @pool.map { |instance| @instance_destructor.call(instance) } unless @instance_destructor.nil?
          @pool.clear()
        }
      end
    end
  end
end