
module SSE
  #
  # A simple backoff algorithm that can be reset at any time, or reset itself after a given
  # interval has passed without errors.
  #
  class Backoff
    def initialize(base_interval, max_interval, auto_reset_interval = 60)
      @base_interval = base_interval
      @max_interval = max_interval
      @auto_reset_interval = auto_reset_interval
      @attempts = 0
      @last_good_time = nil
      @jitter_rand = Random.new
    end

    attr_accessor :base_interval

    def next_interval
      if !@last_good_time.nil? && (Time.now.to_i - @last_good_time) >= @auto_reset_interval
        @attempts = 0
      end
      @last_good_time = nil
      if @attempts == 0
        @attempts += 1
        return 0
      end
      @last_good_time = nil
      target = ([@base_interval * (2 ** @attempts), @max_interval].min).to_f
      @attempts += 1
      (target / 2) + @jitter_rand.rand(target / 2)
    end

    def mark_success
      @last_good_time = Time.now.to_i if @last_good_time.nil?
    end
  end
end
