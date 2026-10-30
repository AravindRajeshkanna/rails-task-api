class WebhookDelivery < ApplicationRecord
  belongs_to :webhook

  # The delivery log is for finding out why an endpoint did not get something; each row holds a snapshot of the event (task and comment
  # content), so it is kept for a month and no longer (PurgeWebhookDeliveriesJob).
  RETENTION = 30.days

  scope :expired, -> { where(created_at: ...RETENTION.ago) }
  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def status
    return "delivered" if delivered_at
    error.present? ? "failed" : "pending"
  end
end
