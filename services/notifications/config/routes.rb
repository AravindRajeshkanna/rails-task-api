Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  # Liveness for Kubernetes: also fails when the SQS consumer stopped polling.
  get "healthz" => "health#show"
end
