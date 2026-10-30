# Rack::Attack throttles abusive clients before they reach Rails.
#
# Counters live in the Rails cache (Solid Cache in production). Controller-level
# `rate_limit` (Rails 8) guards sign-up / login / password reset per IP; these rules
# add a global ceiling per IP, per bearer token and per account.
class Rack::Attack
  # Authenticated traffic is limited per bearer token, anonymous traffic per IP.
  throttle("api/token", limit: 600, period: 5.minutes) do |request|
    if request.path.start_with?("/api/") && (header = request.get_header("HTTP_AUTHORIZATION"))
      Session.digest(header.split.last)
    end
  end

  # The requests that cost the most get a smaller budget of their own, on top of the general one: a client polling a dashboard or a search box in a loop
  # should run out of that budget, not out of the budget for everything it does. 120 of them in five minutes is one every 2.5 seconds, all day.
  EXPENSIVE_PATHS = %r{\A/api/v1/(search|activity|graphql)\b|/(analytics|audit_events|summary)\z}

  throttle("api/expensive", limit: 120, period: 5.minutes) do |request|
    if request.path.match?(EXPENSIVE_PATHS) && (header = request.get_header("HTTP_AUTHORIZATION"))
      Session.digest(header.split.last)
    end
  end

  throttle("api/ip", limit: 300, period: 5.minutes) do |request|
    request.ip if request.path.start_with?("/api/")
  end

  # Slow credential stuffing against a single account, whichever IPs it comes from.
  throttle("logins/email", limit: 5, period: 1.minute) do |request|
    if request.path == "/api/v1/session" && request.post?
      email = Rack::Attack.email_from(request)
      email.to_s.strip.downcase.presence
    end
  end

  # Rack::Attack runs before Rails parses the body, and request.params ignores JSON.
  def self.email_from(request)
    if request.media_type == "application/json"
      body = request.body.read(4_096).to_s
      request.body.rewind
      JSON.parse(body)["email_address"] if body.start_with?("{")
    else
      request.params["email_address"]
    end
  rescue JSON::ParserError, TypeError
    nil
  end

  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"]
    retry_after = (match_data[:period] - (match_data[:epoch_time] % match_data[:period])).to_i

    body = ErrorSerializer.new(
      status: 429, code: "rate_limited", message: "Too many requests. Retry in #{retry_after} seconds.",
      request_id: request.env["action_dispatch.request_id"]
    )
    [ 429, { "content-type" => "application/json", "retry-after" => retry_after.to_s }, [ body.to_json ] ]
  end
end

# Off in the test suite (its cache is a null store); throttling specs switch it on explicitly.
# RACK_ATTACK_ENABLED=false is also the lever for a load test (loadtest/README.md), which would
# otherwise measure 429s, and for switching throttling off in an emergency without a deploy.
Rack::Attack.enabled = ENV.fetch("RACK_ATTACK_ENABLED", (!Rails.env.test?).to_s) == "true"
