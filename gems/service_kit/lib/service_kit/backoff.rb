module ServiceKit
  # Exponential backoff with jitter (ADR 58). Without the jitter, everything that failed in the same second retries in the same second, and an outage that
  # ended is followed by a stampede that causes the next one. "Equal jitter": half of the exponential delay is fixed, half is random, so retries spread out
  # over the second half of each interval and never come sooner than half of it.
  #
  #   ServiceKit::Backoff.delay(attempts: 3)               # between 4 and 8 seconds (2**3 = 8)
  #   ServiceKit::Backoff.delay(attempts: 20, cap: 900)    # between 450 and 900 seconds, whatever the attempt count
  module Backoff
    module_function

    def delay(attempts:, base: 2, cap: 900, random: Random)
      ceiling = [ base**attempts, cap ].min.to_f
      (ceiling / 2) + random.rand(ceiling / 2)
    end
  end
end
