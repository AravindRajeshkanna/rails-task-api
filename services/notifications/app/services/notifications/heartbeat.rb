module Notifications
  # When the consumer last finished a poll. A consumer that has stopped (crashed thread, lost credentials)
  # leaves the web process up, so liveness has to look at this, not at Puma.
  module Heartbeat
    STALE_AFTER = 120 # seconds; a long poll lasts 20

    @last = nil
    @enabled = false

    class << self
      def enable! = (@enabled = true; beat!)
      def beat! = @last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def age = @last && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last
      def healthy? = !@enabled || (age && age < STALE_AFTER)
      def reset! = (@enabled = false; @last = nil)
    end
  end
end
