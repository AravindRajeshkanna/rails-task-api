require "service_kit/circuit_breaker"
require "service_kit/backoff"

# What happens when a circuit breaker (ServiceKit::CircuitBreaker) changes state: a counter, and a log line an alert can be built on. The state itself is a
# gauge refreshed at scrape time (Observability::Collector). Breakers are created where they are used (Ai::Gateway::Remote and Local), not here, because
# the exceptions they count are autoloaded constants that must not be referenced while the application boots.
ServiceKit::CircuitBreaker.observer = lambda do |name, from, to|
  Observability::Metrics::CIRCUIT_TRANSITIONS.increment(labels: { breaker: name.to_s, to: to.to_s })
  Rails.event.notify("circuit.#{to}", breaker: name.to_s, from: from.to_s)
end
