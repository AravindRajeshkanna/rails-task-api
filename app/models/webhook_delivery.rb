class WebhookDelivery < ApplicationRecord
  belongs_to :webhook

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def status
    return "delivered" if delivered_at
    error.present? ? "failed" : "pending"
  end
end
