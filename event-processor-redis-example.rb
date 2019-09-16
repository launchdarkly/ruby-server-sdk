require "launchdarkly-server-sdk"
require "redis"
require "connection_pool"

$flag_key = "test-flag"
$user_key = "test-user"

# This is an example of using Redis both for retrieving flags and for storing events.
#
# For flags, we use the use_ldd option (to tell the SDK to the feature store as its
# sole data source, rather than connecting to LaunchDarkly) and Integrations::Redis.
# It expects flags to be stored in the same format that the LaunchDarkly SDKs and the
# Relay Proxy would store them: that is, the JSON encoding of a flag whose flag key
# is X should be stored as hash field X under the Redis key "launchdarkly:features".
#
# For events, we implement our own component that dumps all event data into Redis,
# into a list with the key "eventlist", where some other component will retrieve and
# process it.
#
# We assume that Redis is running at the default location of localhost:6379.
#
# Example usage:
# redis-cli> HSET launchdarkly:features test-flag "{\"key\":\"test-flag\",\"on\":false,\"offVariation\":0,\"variations\":[\"yes\",\"no\"]}"
# $ bundle exec ruby event-processor-redis-example
# Flag value is yes
# redis-cli> LRANGE eventlist 0 99     (shows "feature" event followed by "custom" event)

# This example simulates just one request cycle, but in real life we might be using
# multiple client instances to handle multiple requests. It's desirable to share the
# Redis resources, and the feature store instance (since the feature store maintains
# an in-memory cache).
$redis_connection_pool = ConnectionPool.new(size: 10) do
  Redis.new
end
$shared_feature_store = LaunchDarkly::Integrations::Redis::new_feature_store({})

class RedisEventSink
  include LaunchDarkly::Interfaces::EventProcessor
  
  def initialize(pool)
    # We'll create a new Redis client here, but we could use a connection pool
    @redis = Redis::new
    @list_key = "eventlist"
    @events_json = []
  end

  def add_event(event)
    event[:creationDate] = (Time.now.to_f * 1000).to_i
    # In this implementation, we'll just save up the events in memory until the
    # application calls flush (e.g. after finishing the current web request)
    @events_json.push(JSON.dump(event))
  end

  def flush
    if @events_json.size
      @redis.rpush(@list_key, @events_json)
      @events_json = []
    end
  end

  def stop
  end
end

# This function simulates some SDK actions taking place for a single web request.
# We'll create our own client instance scoped to this requset; since the client in
# this configuration makes no HTTP requests and has no state (other than the Redis
# database, and the RedisEventSink which is also locally scoped), it is lightweight.
def do_something
  user = { key: $user_key }
  config = LaunchDarkly::Config.new({
    event_processor: RedisEventSink.new($redis_connection_pool),
    feature_store: $shared_feature_store,
    use_ldd: true
  })
  client = LaunchDarkly::LDClient.new("irrelevant SDK key", config)
  # not connecting to LaunchDarkly, so SDK key doesn't matter

  # Evaluate a flag - this generates a "feature" event
  flag_value = client.variation($flag_key, user, nil)
  puts "Flag value is #{flag_value}"

  # Also send a custom event
  client.track("custom-event-key", user)

  client.flush  # this calls RedisEventSink.flush
end

do_something
