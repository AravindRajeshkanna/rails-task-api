require "concurrent/map"

module ServiceKit
  # A circuit breaker for a dependency that can fail slowly (ADR 58). When a dependency is down, every call that waits out its timeout holds a thread
  # for nothing and makes the outage worse; after a few consecutive failures the breaker "opens" and calls fail immediately, for a while, then one probe is
  # allowed through to find out whether it has recovered.
  #
  #   breaker = ServiceKit::CircuitBreaker.new(:ai_service, failure_threshold: 5, reset_timeout: 30, exceptions: [ Ai::Unavailable ])
  #   breaker.call { post_to_the_ai_service }     # raises CircuitBreaker::OpenError, at once, while it is open
  #
  #   closed    calls go through; `failure_threshold` consecutive failures (within `window` seconds of each other) open it
  #   open      calls raise OpenError for `reset_timeout` seconds (doubling after each failed probe, up to `max_reset_timeout`)
  #   half_open exactly one probe call goes through; its success closes the breaker, its failure reopens it
  #
  # Only the listed `exceptions` count as failures: a validation error or a 4xx is the caller's mistake, not the dependency being down. State is
  # per process (shared-nothing): each pod learns about an outage on its own within `failure_threshold` calls, and needs nothing to be up to do so.
  class CircuitBreaker
    class OpenError < StandardError
      attr_reader :breaker, :retry_after

      def initialize(breaker, retry_after)
        @breaker = breaker
        @retry_after = retry_after.ceil
        super("circuit #{breaker} is open; retry in #{@retry_after}s")
      end
    end

    STATES = %i[closed half_open open].freeze

    class << self
      # Called as observer.call(name, from, to) on every transition: where metrics and logs are wired.
      attr_accessor :observer

      def registry = (@registry ||= Concurrent::Map.new)

      # The named breaker, created with these options the first time.
      def for(name, **options) = registry.compute_if_absent(name.to_sym) { new(name, **options) }

      def reset_all! = registry.clear
    end

    attr_reader :name

    def initialize(name, failure_threshold: 5, window: 30, reset_timeout: 30, max_reset_timeout: 300, exceptions: [ StandardError ], clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @name = name.to_sym
      @failure_threshold = failure_threshold
      @window = window
      @base_reset_timeout = reset_timeout
      @max_reset_timeout = max_reset_timeout
      @exceptions = Array(exceptions)
      @clock = clock
      @mutex = Mutex.new
      reset
    end

    def call
      permit
      result = yield
      succeeded
      result
    rescue *@exceptions
      failed
      raise
    end

    def state = @mutex.synchronize { current_state }

    def open? = state == :open

    def reset = @mutex.synchronize do
      @state = :closed
      @failures = 0
      @last_failure_at = nil
      @opened_until = nil
      @reset_timeout = @base_reset_timeout
      @probing = false
    end

    private
      # :open becomes :half_open on its own once the timeout has passed (without a call to notice it, state still reports the truth).
      def current_state
        @state == :open && @clock.call >= @opened_until ? :half_open : @state
      end

      def permit
        @mutex.synchronize do
          case current_state
          when :closed then nil
          when :open then raise OpenError.new(@name, @opened_until - @clock.call)
          when :half_open
            raise OpenError.new(@name, 1) if @probing # someone else is already finding out

            transition(:half_open)
            @probing = true
          end
        end
      end

      def succeeded
        @mutex.synchronize do
          @failures = 0
          @probing = false
          if @state != :closed
            @reset_timeout = @base_reset_timeout
            transition(:closed)
          end
        end
      end

      def failed
        @mutex.synchronize do
          now = @clock.call
          @failures = @last_failure_at && now - @last_failure_at > @window ? 1 : @failures + 1
          @last_failure_at = now
          if @probing # the probe failed: stay away for longer
            @reset_timeout = [ @reset_timeout * 2, @max_reset_timeout ].min
            @probing = false
            open_circuit(now)
          elsif @state == :closed && @failures >= @failure_threshold
            open_circuit(now)
          end
        end
      end

      def open_circuit(now)
        @opened_until = now + @reset_timeout
        transition(:open)
      end

      def transition(to)
        from = @state
        return if from == to

        @state = to
        self.class.observer&.call(@name, from, to)
      end
  end
end
