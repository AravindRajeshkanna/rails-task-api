class WebhookResource < ApplicationResource
  attributes :id, :project_id, :url, :events, :active, :created_at, :updated_at

  # Whether a new signing secret is being rotated in (ADR 78), and since when. Read from a column: nothing here decrypts a secret.
  attribute(:rotating) { |webhook| webhook.rotating? }
  attributes :rotation_started_at
end
