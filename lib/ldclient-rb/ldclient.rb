require "faraday/http_cache"
require "json"
require "digest/sha1"
require "thread"
require "logger"
require "net/http/persistent"
require "benchmark"
require "hashdiff"

module LaunchDarkly
  BUILTINS = [:key, :ip, :country, :email, :firstName, :lastName, :avatar, :name, :anonymous]

  #
  # A client for the LaunchDarkly API. Client instances are thread-safe. Users
  # should create a single client instance for the lifetime of the application.
  #
  #
  class LDClient
    #
    # Creates a new client instance that connects to LaunchDarkly. A custom
    # configuration parameter can also supplied to specify advanced options,
    # but for most use cases, the default configuration is appropriate.
    #
    #
    # @param api_key [String] the API key for your LaunchDarkly account
    # @param config [Config] an optional client configuration object
    #
    # @return [LDClient] The LaunchDarkly client instance
    def initialize(api_key, config = Config.default)
      @queue = Queue.new
      @api_key = api_key
      @config = config
      @client = Faraday.new do |builder|
        builder.use :http_cache, store: @config.store

        builder.adapter :net_http_persistent
      end
      @offline = false

      if @config.stream?
        @stream_processor = StreamProcessor.new(api_key, config)
      end

      @worker = create_worker
    end

    def flush
      events = []
      begin
        loop do
          events << @queue.pop(true)
        end
      rescue ThreadError
      end

      if !events.empty?
        post_flushed_events(events)
      end
    end

    def post_flushed_events(events)
      res = log_timings("Flush events") do
        next @client.post (@config.base_uri + "/api/events/bulk") do |req|
          req.headers["Authorization"] = "api_key " + @api_key
          req.headers["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
          req.headers["Content-Type"] = "application/json"
          req.body = events.to_json
          req.options.timeout = @config.read_timeout
          req.options.open_timeout = @config.connect_timeout
        end
      end
      if res.status / 100 != 2
        @config.logger.error("[LDClient] Unexpected status code while processing events: #{res.status}")
      end
    end

    def create_worker
      Thread.new do
        loop do
          begin
            flush

            sleep(@config.flush_interval)
          rescue StandardError => exn
            @config.logger.error("[LDClient] Unexpected exception in create_worker: #{exn.inspect} #{exn}\n\t#{exn.backtrace.join("\n\t")}")
          end
        end
      end
    end

    def get_flag?(key, user, default = false)
      toggle?(key, user, default)
    end

    #
    # Calculates the value of a feature flag for a given user. At a minimum,
    # the user hash should contain a +:key+ .
    #
    # @example Basic user hash
    #      {key: "user@example.com"}
    #
    # For authenticated users, the +:key+ should be the unique identifier for
    # your user. For anonymous users, the +:key+ should be a session identifier
    # or cookie. In either case, the only requirement is that the key
    # is unique to a user.
    #
    # You can also pass IP addresses and country codes in the user hash.
    #
    # @example More complete user hash
    #   {key: "user@example.com", ip: "127.0.0.1", country: "US"}
    #
    # Countries should be sent as ISO 3166-1 alpha-2 codes.
    #
    # The user hash can contain arbitrary custom attributes stored in a +:custom+ sub-hash:
    #
    # @example A user hash with custom attributes
    #   {key: "user@example.com", custom: {customer_rank: 1000, groups: ["google", "microsoft"]}}
    #
    # Attribute values in the custom hash can be integers, booleans, strings, or
    #   lists of integers, booleans, or strings.
    #
    # @param key [String] the unique feature key for the feature flag, as shown
    #   on the LaunchDarkly dashboard
    # @param user [Hash] a hash containing parameters for the end user requesting the flag
    # @param default=false [Boolean] the default value of the flag
    #
    # @return [Boolean] whether or not the flag should be enabled, or the
    #   default value if the flag is disabled on the LaunchDarkly control panel
    def toggle?(key, user, default = false)
      return default if @offline

      unless user
        @config.logger.error("[LDClient] Must specify user")
        return default
      end

      if @config.stream? && !@stream_processor.started?
        @stream_processor.start
      end

      if @config.stream? && @stream_processor.initialized?
        feature = get_streamed_flag(key)
      else
        feature = get_flag_int(key)
      end
      value = evaluate(feature, user)
      value.nil? ? default : value

      add_event(kind: "feature", key: key, user: user, value: value)
      LDNewRelic.annotate_transaction(key, value)
      return value
    rescue StandardError => error
      @config.logger.error("[LDClient] Unhandled exception in toggle: (#{error.class.name}) #{error}\n\t#{error.backtrace.join("\n\t")}")
      default
    end

    def add_event(event)
      return if @offline

      if @queue.length < @config.capacity
        event[:creationDate] = (Time.now.to_f * 1000).to_i
        @queue.push(event)

        if !@worker.alive?
          @worker = create_worker
        end
      else
        @config.logger.warn("[LDClient] Exceeded event queue capacity. Increase capacity to avoid dropping events.")
      end
    end

    #
    # Registers the user
    #
    # @param [Hash] The user to register
    #
    def identify(user)
      add_event(kind: "identify", key: user[:key], user: user)
    end

    def set_offline
      @offline = true
    end

    def set_online
      @offline = false
    end

    def is_offline?
      @offline
    end

    #
    # Tracks that a user performed an event
    #
    # @param event_name [String] The name of the event
    # @param user [Hash] The user that performed the event. This should be the same user hash used in calls to {#toggle?}
    # @param data [Hash] A hash containing any additional data associated with the event
    #
    # @return [void]
    def track(event_name, user, data)
      add_event(kind: "custom", key: event_name, user: user, data: data)
    end

    #
    # Returns the key of every feature
    #
    def feature_keys
      get_features.map { |feature| feature[:key] }
    end

    #
    # Returns all features
    #
    def get_features
      res = make_request "/api/features"

      if res.status / 100 == 2
        return JSON.parse(res.body, symbolize_names: true)[:items]
      else
        @config.logger.error("[LDClient] Unexpected status code #{res.status}")
      end
    end

    def get_streamed_flag(key)
      feature = get_flag_stream(key)
      if @config.debug_stream?
        polled = get_flag_int(key)
        diff = HashDiff.diff(feature, polled)
        if not diff.empty?
          @config.logger.error("Streamed flag differs from polled flag " + diff.to_s)
        end
      end
      feature
    end

    def get_flag_stream(key)
      @stream_processor.get_feature(key)
    end

    def get_flag_int(key)
      res = log_timings("Feature request") do
        next make_request "/api/eval/features/" + key
      end

      if res.status == 401
        @config.logger.error("[LDClient] Invalid API key")
        return nil
      end

      if res.status == 404
        @config.logger.error("[LDClient] Unknown feature key: #{key}")
        return nil
      end

      if res.status / 100 != 2
        @config.logger.error("[LDClient] Unexpected status code #{res.status}")
        return nil
      end

      JSON.parse(res.body, symbolize_names: true)
    end

    def make_request(path)
      @client.get (@config.base_uri + path) do |req|
        req.headers["Authorization"] = "api_key " + @api_key
        req.headers["User-Agent"] = "RubyClient/" + LaunchDarkly::VERSION
        req.options.timeout = @config.read_timeout
        req.options.open_timeout = @config.connect_timeout
      end
    end

    def param_for_user(feature, user)
      return nil unless user[:key]

      id_hash = user[:key]
      if user[:secondary]
        id_hash += "." + user[:secondary]
      end

      hash_key = "%s.%s.%s" % [feature[:key], feature[:salt], id_hash]

      hash_val = (Digest::SHA1.hexdigest(hash_key))[0..14]
      hash_val.to_i(16) / Float(0xFFFFFFFFFFFFFFF)
    end

    def match_target?(target, user)
      attrib = target[:attribute].to_sym

      if BUILTINS.include?(attrib)
        return false unless user[attrib]

        u_value = user[attrib]
        return target[:values].include? u_value
      else # custom attribute
        return false unless user[:custom]
        return false unless user[:custom].include? attrib

        u_value = user[:custom][attrib]
        if u_value.is_a? Array
          return ! ((target[:values] & u_value).empty?)
        else
          return target[:values].include? u_value
        end

        return false
      end
    end

    def match_user?(variation, user)
      if variation[:userTarget]
        return match_target?(variation[:userTarget], user)
      end
      false
    end

    def find_user_match(feature, user)
      feature[:variations].each do |variation|
        return variation[:value] if match_user?(variation, user)
      end
      nil
    end

    def match_variation?(variation, user)
      variation[:targets].each do |target|
        if !!variation[:userTarget] && target[:attribute].to_sym == :key
          next
        end

        if match_target?(target, user)
          return true
        end
      end
      false
    end

    def find_target_match(feature, user)
      feature[:variations].each do |variation|
        return variation[:value] if match_variation?(variation, user)
      end
      nil
    end

    def find_weight_match(feature, param)
      total = 0.0
      feature[:variations].each do |variation|
        total += variation[:weight].to_f / 100.0

        return variation[:value] if param < total
      end

      nil
    end

    def evaluate(feature, user)
      return nil if feature.nil?
      return nil unless feature[:on]

      param = param_for_user(feature, user)
      return nil if param.nil?

      value = find_user_match(feature, user)
      return value if !value.nil?

      value = find_target_match(feature, user)
      return value if !value.nil?

      find_weight_match(feature, param)
    end

    def log_timings(label, &block)
      return block.call unless @config.log_timings? && @config.logger.debug?
      res = nil
      exn = nil
      bench = Benchmark.measure do
        begin
          res = block.call
        rescue StandardError => e
          exn = e
        end
      end
      @config.logger.debug { "[LDClient] #{label} timing: #{bench}".chomp }
      raise exn if exn
      res
    end

    private :post_flushed_events, :add_event, :get_streamed_flag, :get_flag_stream, :get_flag_int, :make_request, :param_for_user, :match_target?, :match_user?, :match_variation?, :evaluate, :create_worker, :log_timings
  end
end
