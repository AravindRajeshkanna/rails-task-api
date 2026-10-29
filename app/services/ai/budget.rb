module Ai
  # Daily token budgets (UTC day) per user and per project, read from the AiUsage ledger. A soft
  # limit: two requests racing at the edge can overshoot by one call, which is acceptable for cost
  # control and avoids locking on the hot path.
  class Budget
    def initialize(user: nil, project: nil, config: Ai.config)
      @user = user
      @project = project
      @config = config
    end

    def check!
      return if within?(user_used, @config.daily_tokens_per_user) && within?(project_used, @config.daily_tokens_per_project)

      raise BudgetExceeded.new(retry_after: seconds_until_reset)
    end

    # What the caller can see about their own spending (GET /api/v1/ai/usage).
    def summary
      scope = AiUsage.successful.since(day_start).where(user_id: @user&.id)
      {
        day: day_start.to_date.iso8601,
        tokens_used: user_used,
        daily_token_limit: @config.daily_tokens_per_user,
        tokens_remaining: [ @config.daily_tokens_per_user - user_used, 0 ].max,
        calls: scope.count,
        cost_usd: (scope.sum(:cost_micros) / 1_000_000.0).round(4),
        resets_at: (day_start + 1.day).iso8601
      }
    end

    private
      def within?(used, limit) = used.nil? || used < limit

      def user_used = (@user && AiUsage.successful.since(day_start).where(user_id: @user.id).tokens) || nil
      def project_used = (@project && AiUsage.successful.since(day_start).where(project_id: @project.id).tokens) || nil

      def day_start = Time.current.utc.beginning_of_day
      def seconds_until_reset = (day_start + 1.day - Time.current).ceil
  end
end
