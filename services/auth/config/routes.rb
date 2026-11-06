Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Public keys for verifying access tokens; every service fetches and caches this.
  get ".well-known/jwks.json", to: "jwks#show"

  # Same paths and shapes as the monolith's own endpoints, so the load balancer can route them here
  # without clients noticing (strangler fig). The session response adds refresh_token.
  namespace :api do
    namespace :v1 do
      resources :registrations, only: :create
      resource :session, only: %i[create destroy] do
        post :refresh, on: :collection
      end
      resources :passwords, only: %i[create update], param: :token
      # In-cluster only: the ingress does not list this path (deploy/helm/values/auth.yaml).
      resources :credential_checks, only: :create
    end
  end

  match "*unmatched", to: "errors#not_found", via: :all
end
