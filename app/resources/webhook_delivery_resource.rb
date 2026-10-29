class WebhookDeliveryResource < ApplicationResource
  attributes :id, :webhook_id, :event, :status, :response_status, :error,
             :duration_ms, :payload, :delivered_at, :created_at
end
