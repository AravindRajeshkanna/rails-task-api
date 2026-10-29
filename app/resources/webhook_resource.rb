class WebhookResource < ApplicationResource
  attributes :id, :project_id, :url, :events, :active, :created_at, :updated_at
end
