# A fair share of the database for each tenant (ADR 62). The per-token and per-IP limits stop one client; they do not stop one organization with
# a hundred clients (a misbehaving integration, a migration script, a bulk import) from using up the write capacity everyone shares. Each organization
# gets a budget of changes per five minutes, counted when a write is authorized, and past it gets 429 with a Retry-After until the window turns over.
# Reads are not charged: they can go to a replica, and are cheap to refuse under load (LoadShedder).
module OrganizationBudget
  PERIOD = 5.minutes

  class Exceeded < StandardError
    attr_reader :retry_after

    def initialize(retry_after)
      @retry_after = retry_after
      super("This organization has made too many changes in a short time. Retry in #{retry_after} seconds.")
    end
  end

  module_function

  def limit = Rails.configuration.x.organization_writes_per_period

  # Counts one write for the organization; raises Exceeded when the budget for the current window is spent. Fails open: if the cache is down
  # a tenant is not throttled, which is the lesser evil.
  def charge!(organization_id, now: Time.current)
    window = now.to_i / PERIOD.to_i
    count = Rails.cache.increment("org_budget:#{organization_id}:#{window}", 1, expires_in: PERIOD)
    return unless count && count > limit

    retry_after = PERIOD.to_i - (now.to_i % PERIOD.to_i)
    Rails.event.notify("organization_budget.exceeded", organization_id: organization_id, retry_after: retry_after)
    raise Exceeded.new(retry_after)
  end
end
