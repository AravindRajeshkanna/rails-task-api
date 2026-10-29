# One row per model call (success or failure): feeds the daily budgets in Ai::Budget and cost reporting.
class AiUsage < ApplicationRecord
  OUTCOMES = %w[ok error].freeze

  belongs_to :user, optional: true
  belongs_to :project, optional: true

  validates :feature, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :since, ->(time) { where(created_at: time..) }
  scope :successful, -> { where(outcome: "ok") }

  def self.tokens = sum("input_tokens + output_tokens")
end
