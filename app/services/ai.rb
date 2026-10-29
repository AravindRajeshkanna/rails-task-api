# Namespace for the AI layer. Inference itself lives in the ai_core gem; this layer adds what needs the
# database and the signed-in user: budgets, usage tracking, context gathering and authorization.
module Ai
  class Error < StandardError; end

  # AI is not configured (no AI_PROVIDER, or the remote service URL is missing).
  class Disabled < Error; end

  # The model provider is throttling or down; try again shortly.
  class Unavailable < Error; end

  # The model answered with something that failed validation.
  class InvalidResponse < Error; end

  # A daily token budget is used up. +retry_after+ is the seconds until it resets.
  class BudgetExceeded < Error
    attr_reader :retry_after

    def initialize(message = "The daily AI budget has been used up", retry_after: 1.hour.to_i)
      super(message)
      @retry_after = retry_after
    end
  end

  def self.config = Rails.configuration.x.ai
  def self.enabled? = Gateway.current.enabled?
  def self.embeddings? = config.embeddings && enabled?
end
